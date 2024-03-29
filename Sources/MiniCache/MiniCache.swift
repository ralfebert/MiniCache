// MIT License
//
// Copyright (c) 2023 Ralf Ebert
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import CoreData
import CoreDataModelDescription
import Foundation
import os

public class MiniCache<Key: Codable, Value: Codable> {

    let cacheManager: MiniCacheManager
    let cacheName: String
    let cacheVersion: CacheVersion
    let maxAge: CacheMaxAge

    fileprivate init(cacheManager: MiniCacheManager, cacheName: String, cacheVersion: CacheVersion, maxAge: CacheMaxAge) {
        self.cacheManager = cacheManager
        self.cacheName = cacheName
        self.cacheVersion = cacheVersion
        self.maxAge = maxAge
    }

    public subscript(_ key: Key) -> Value? {
        get {
            self.cacheManager.checkThread()
            return self.object(forKey: key)
        }
        set {
            self.cacheManager.checkThread()
            self.setObject(newValue, forKey: key)
        }
    }

    private func object(forKey key: Key) -> Value? {
        guard let entry = fetchEntry(forKey: key), let data = entry.value.data(using: .utf8) else { return nil }
        do {
            return try self.cacheManager.jsonDecoder.decode(Value.self, from: data)
        } catch {
            os_log("Error for decoding cache value \"%@\": %@", log: self.cacheManager.log, type: .error, String(describing: key), String(describing: error))
            return nil
        }
    }

    private func setObject(_ value: Value?, forKey key: Key) {
        guard let value = value else {
            if let entry = fetchEntry(forKey: key) {
                self.cacheManager.managedObjectContext.delete(entry)
                self.cacheManager.save()
            }
            return
        }
        guard let encodedKey = cacheManager.withErrorHandling({ try self.encode(key) }) else { return }
        guard let encodedValue = cacheManager.withErrorHandling({ try self.encode(value) }) else { return }
        let entry = self.fetchEntry(forKey: key) ?? CacheEntry.create(context: self.cacheManager.managedObjectContext)
        entry.cache = self.cacheName
        entry.cacheVersion = self.cacheVersion.versionString
        entry.key = encodedKey
        entry.value = encodedValue
        entry.date = self.cacheManager.clock()
        self.cacheManager.save()
    }

    private func fetchEntry(forKey key: Key) -> CacheEntry? {
        self.purgeExpiredEntries()
        return self.cacheManager.withErrorHandling { () -> [CacheEntry] in
            let fetchRequest: NSFetchRequest<CacheEntry> = CacheEntry.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "cache == %@ && key == %@", self.cacheName, try self.encode(key))
            return try self.cacheManager.managedObjectContext.fetch(fetchRequest)
        }?.first
    }

    func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try self.cacheManager.jsonEncoder.encode(value)
        if let string = String(data: data, encoding: .utf8) {
            return string
        } else {
            throw StringEncodingError()
        }
    }

    struct StringEncodingError: Error {}

    private func purgeExpiredEntries() {
        let request: NSFetchRequest<NSFetchRequestResult> = NSFetchRequest(entityName: CacheEntry.entityName)
        request.predicate = NSPredicate(format: "cache == %@ && (cacheVersion != %@ || %@ > date)", self.cacheName, self.cacheVersion.versionString, self.cacheManager.clock().addingTimeInterval(-self.maxAge.timeInterval) as NSDate)
        self.cacheManager.withErrorHandling {
            _ = try self.cacheManager.managedObjectContext.execute(NSBatchDeleteRequest(fetchRequest: request))
        }
    }

}

public class MiniCacheManager {

    let name: String
    let jsonEncoder = { () -> JSONEncoder in
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    let jsonDecoder = JSONDecoder()
    let ownerThread: Thread
    let log: OSLog
    var clock = { Date() }

    /// Creates a new MiniCacheManager.
    ///
    /// - Parameters:
    ///   - name: Name of the cache manager. Used as name for the database file - allows to have multiple, separate cache managers in the same app.
    ///   - ownerThread: Only this thread is allowed to use the caches.
    ///   - persistentContainer: Optionally, you can pass your own persistentContainer. This needs to have set up a 'CacheEntry' entity in the same way as in this package (see MiniCacheManager.managedObjectModel)
    public init(name: String, ownerThread: Thread = Thread.current, persistentContainer: NSPersistentContainer? = nil) {
        self.name = name
        self.ownerThread = ownerThread
        self.log = OSLog(subsystem: "MiniCache", category: self.name)
        if let persistentContainer {
            self.persistentContainer = persistentContainer
        }
        self.checkThread()
    }

    private let managedObjectModel = CoreDataModelDescription(
        entities: [
            .entity(
                name: "CacheEntry",
                managedObjectClass: CacheEntry.self,
                attributes: [
                    .attribute(name: "cache", type: .stringAttributeType),
                    .attribute(name: "cacheVersion", type: .stringAttributeType),
                    .attribute(name: "key", type: .stringAttributeType),
                    .attribute(name: "value", type: .stringAttributeType),
                    .attribute(name: "date", type: .dateAttributeType),
                ],
                indexes: [
                    .index(name: "cacheKey", elements: [.property(name: "cache"), .property(name: "key")]),
                ]

            ),
        ]
    ).makeModel()

    static func cacheUrl(name: String) -> URL {
        let storeDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return storeDirectory.appendingPathComponent("\(name).sqlite")
    }

    private lazy var persistentContainer: NSPersistentContainer = {
        let container = NSPersistentContainer(name: self.name, managedObjectModel: self.managedObjectModel)

        let url = Self.cacheUrl(name: self.name)
        os_log("Cache Location: %s", log: self.log, type: .debug, String(describing: url))

        let description = NSPersistentStoreDescription(url: url)
        container.persistentStoreDescriptions = [description]

        container.loadPersistentStores(completionHandler: { _, error in
            if let error = error {
                os_log("Recovering from Core Data error by deleting the cache db - Error: %@", log: self.log, type: .error, String(describing: error))
                try? FileManager.default.removeItem(at: url)
                container.loadPersistentStores(completionHandler: { _, error in
                    if let error = error {
                        self.handleError(error)
                    }
                })
            }
        })
        return container
    }()

    fileprivate var managedObjectContext: NSManagedObjectContext {
        self.persistentContainer.viewContext
    }

    public func cache<Key: Codable, Value: Codable>(cacheName: String, cacheVersion: CacheVersion, maxAge: CacheMaxAge) -> MiniCache<Key, Value> {
        self.checkThread()
        return MiniCache(cacheManager: self, cacheName: cacheName, cacheVersion: cacheVersion, maxAge: maxAge)
    }

    public func clearAll() {
        self.checkThread()
        let request: NSFetchRequest<NSFetchRequestResult> = NSFetchRequest(entityName: CacheEntry.entityName)
        self.withErrorHandling {
            _ = try self.managedObjectContext.execute(NSBatchDeleteRequest(fetchRequest: request))
        }
    }

    fileprivate func checkThread() {
        if Thread.current != self.ownerThread {
            let msg = "Illegal thread usage, MiniCache ownerThread=\(self.ownerThread), actual=\(Thread.current)"
            #if DEBUG
            fatalError(msg)
            #else
            os_log("MiniCache threading error: %@", log: self.log, type: .error, msg)
            #endif
        }
    }

    // Default error handling for errors that shouldn't occur normally: crash in DEBUG mode, log error otherwise
    func handleError(_ error: Error) {
        #if DEBUG
        fatalError("MiniCache error: \(error)")
        #else
        os_log("MiniCache error: %@", log: self.log, type: .error, String(describing: error))
        #endif
    }

    func withErrorHandling<T>(_ block: () throws -> T) -> T? {
        do {
            return try block()
        } catch {
            self.handleError(error)
            return nil
        }
    }

    func save() {
        self.withErrorHandling {
            try self.managedObjectContext.save()
        }
    }

}

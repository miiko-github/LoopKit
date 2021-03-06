//
//  DoseStore.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 1/27/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import CoreData
import LoopKit


public protocol DoseStoreDelegate: class {
    /**
     Asks the delegate to upload recently-added pump events not yet marked as uploaded.
     
     The completion handler must be called in all circumstances, with an array of object IDs that were successfully uploaded and can be purged when they are no longer recent.
     
     - parameter doseStore:  The store instance
     - parameter pumpEvents: The pump events
     - parameter completion: The closure to execute when the upload attempt has finished. If no events were uploaded, call the closure with an empty array.
     - parameter uploadedObjects: The array of object IDs that were successfully uploaded
     */
    func doseStore(_ doseStore: DoseStore, hasEventsNeedingUpload pumpEvents: [PersistedPumpEvent], completion: @escaping (_ uploadedObjects: [NSManagedObjectID]) -> Void)
}


public extension NSNotification.Name {
    /// Notification posted when the ready state was modified.
    public static let DoseStoreReadyStateDidChange = NSNotification.Name(rawValue: "com.loopkit.DoseStore.ReadyStateDidUpdateNotification")

    /// Notification posted when data was modifed.
    public static let DoseStoreValuesDidChange = NSNotification.Name(rawValue: "com.loopkit.DoseStore.ValuesDidChangeNotification")
}


public enum DoseStoreResult<T> {
    case success(T)
    case failure(DoseStore.DoseStoreError)
}


/**
 Manages storage, retrieval, and calculation of insulin pump delivery data.
 
 Pump data are stored in the following tiers:
 
 * In-memory cache, used for IOB and insulin effect calculation
 ```
 0            [1.5 * insulinActionDuration]
 |––––––––––––––––––––—————————––|
 ```
 * On-disk Core Data store, unprotected
 ```
 0                           [24 hours]
 |––––––––––––––––––––––—————————|
 ```
 
 Private members should be assumed to not be thread-safe, and access should be contained to within blocks submitted to `persistenceStore.managedObjectContext`, which executes them on a private, serial queue.
 */
public final class DoseStore {

    public enum ReadyState {
        case needsConfiguration
        case initializing
        case ready
        case failed(DoseStoreError)
    }

    public var readyState = ReadyState.needsConfiguration {
        didSet {
            NotificationCenter.default.post(name: .DoseStoreReadyStateDidChange, object: self)
        }
    }

    public enum DoseStoreError: Error {
        case configurationError
        case initializationError(description: String, recoverySuggestion: String)
        case persistenceError(description: String, recoverySuggestion: String?)
        case fetchError(description: String, recoverySuggestion: String?)

        init?(error: PersistenceController.PersistenceControllerError?) {
            if let error = error {
                self = .persistenceError(description: error.description, recoverySuggestion: error.recoverySuggestion)
            } else {
                return nil
            }
        }
    }

    public weak var delegate: DoseStoreDelegate? {
        didSet {
            isUploadRequestPending = false
        }
    }

    public var insulinActionDuration: TimeInterval? {
        didSet {
            persistenceController.managedObjectContext.perform {
                if let recentValuesStartDate = self.recentValuesStartDate {
                    self.pumpEventQueryAfterDate = max(self.pumpEventQueryAfterDate, recentValuesStartDate)
                }
            }
        }
    }

    public var basalProfile: BasalRateSchedule? {
        didSet {
            persistenceController.managedObjectContext.perform {
                self.clearReservoirNormalizedDoseCache()
            }
        }
    }

    public var insulinSensitivitySchedule: InsulinSensitivitySchedule?

    @available(*, deprecated, message: "Use init(insulinActionDuration:basalProfile:insulinSensitivitySchedule:) instead")
    public convenience init(pumpID: String?, insulinActionDuration: TimeInterval?, basalProfile: BasalRateSchedule?, insulinSensitivitySchedule: InsulinSensitivitySchedule?) {
        self.init(insulinActionDuration: insulinActionDuration, basalProfile: basalProfile, insulinSensitivitySchedule: insulinSensitivitySchedule)
    }

    /// Initializes the store with configuration values
    ///
    /// - Parameters:
    ///   - insulinActionDuration: The length of time insulin has an effect on blood glucose
    ///   - basalProfile: The daily schedule of basal insulin rates
    ///   - insulinSensitivitySchedule: The daily schedule of insulin sensitivity (also known as ISF)
    public init(insulinActionDuration: TimeInterval?, basalProfile: BasalRateSchedule?, insulinSensitivitySchedule: InsulinSensitivitySchedule?, databasePath: String = "com.loudnate.InsulinKit") {
        self.insulinActionDuration = insulinActionDuration
        self.insulinSensitivitySchedule = insulinSensitivitySchedule
        self.basalProfile = basalProfile
        self.pumpEventQueryAfterDate = recentValuesStartDate ?? Date.distantPast

        readyState = .initializing

        persistenceController = PersistenceController(databasePath: databasePath, readyCallback: { [unowned self] (error) -> Void in
            if let error = error {
                self.readyState = .failed(.initializationError(description: error.localizedDescription, recoverySuggestion: error.recoverySuggestion))
            } else {
                self.persistenceController.managedObjectContext.perform {
                    // Find the newest PumpEvent date we have
                    if let lastEvent = PumpEvent.singleObjectInContext(self.persistenceController.managedObjectContext,
                        predicate: nil,
                        sortedBy: "date",
                        ascending: false
                    ) {
                        self.pumpEventQueryAfterDate = lastEvent.date
                    }

                    // Warm the state of the reservoir data.
                    // These are in reverse-chronological order
                    // To populate `lastReservoirVolumeDrop`, we set the most recent 2 in-order.
                    let recentReservoirObjects = self.validateReservoirContinuity()
                    if recentReservoirObjects.count > 1 {
                        self.lastReservoirObject = recentReservoirObjects[1]
                    }
                    self.lastReservoirObject = recentReservoirObjects.first

                    self.readyState = .ready
                }
            }
        })
    }

    /// Clears all pump data from the on-disk store.
    ///
    /// Calling this method may result in data loss, as there is no check to ensure data has been synced first.
    ///
    /// - Parameter completion: A closure to call after the reset has completed
    public func resetPumpData(completion: ((_ error: Error?) -> Void)? = nil) {
        persistenceController.managedObjectContext.perform { [unowned self] in
            do {
                try self.purgeReservoirObjects()
                try self.purgePumpEventObjects()
            } catch let error {
                completion?(error)
                return
            }

            self.persistenceController.save { (error) in
                self.clearReservoirCache()
                self.pumpEventQueryAfterDate = self.recentValuesStartDate ?? .distantPast
                self.lastAddedPumpEvents = .distantPast

                completion?(error)
            }
        }
    }

    private var persistenceController: PersistenceController!

    private var purgeableValuesPredicate: NSPredicate {
        return NSPredicate(format: "date < %@", cacheStartDate as NSDate)
    }

    /// The maximum length of time to keep data around.
    /// Dose data is unprotected on disk, and should only remain persisted long enough to support dosing algorithms and until its persisted by the delegate.
    private var cacheStartDate: Date {
        return Calendar.current.date(byAdding: .day, value: -1, to: Date())!
    }

    /// A incremental cache of total insulin delivery since the last date requested by a client, used to avoid repeated work
    private var totalDeliveryCache: InsulinValue?

    /// The definition of "recency". Deprecated.
    private var recentValuesStartDate: Date? {
        if let insulinActionDuration = insulinActionDuration {
            let calendar = Calendar.current

            return min(calendar.startOfDay(for: Date()), Date(timeIntervalSinceNow: -insulinActionDuration * 3 / 2 - TimeInterval(minutes: 5)))
        } else {
            return nil
        }
    }

    // MARK: - Reservoir Data

    /// The last-created reservoir object.
    /// *This setter should only be called from within a managed object context block.*
    private var lastReservoirObject: Reservoir? {
        didSet {
            if let oldValue = oldValue, let newValue = lastReservoirObject {
                lastReservoirVolumeDrop = oldValue.unitVolume - newValue.unitVolume
            }
        }
    }

    // The last change in reservoir volume.
    public private(set) var lastReservoirVolumeDrop: Double = 0

    // The last-saved reservoir value
    public var lastReservoirValue: ReservoirValue? {
        return lastReservoirObject
    }

    /// An incremental cache of normalized doses based on reservoir records, used to avoid repeated work.
    private var recentReservoirNormalizedDoseEntriesCache: [DoseEntry]?

    // Whether the current recent state of the stored reservoir data is considered
    // continuous and reliable for the derivation of insulin effects
    public var areReservoirValuesValid: Bool {
        return areReservoirValuesContinuous && !primeEventExistsWithinInsulinOnboardTime
    }
    
    // Are the reservoir values continuous enough to make a accurate derivation of insulin effects
    private(set) var areReservoirValuesContinuous = false
    
    // Does a prime event exist during Insulin Onboard time that would make reservoir values unusable
    private(set) var primeEventExistsWithinInsulinOnboardTime = false
    
    /// Validates the current reservoir data for reliability in glucose effect calculation at the specified date
    ///
    /// *This method should only be called from within a managed object context block.*
    ///
    /// - Parameter date: The date to base the continuity calculation on. Defaults to now.
    /// - Returns: The array of reservoir data used in the calculation
    @discardableResult
    private func validateReservoirContinuity(at date: Date = Date()) -> [Reservoir] {
        if let insulinActionDuration = insulinActionDuration {
            // Consider any entries longer than 30 minutes, or with a value of 0, to be unreliable
            let maximumInterval = TimeInterval(minutes: 30)
            let continuityStartDate = date.addingTimeInterval(-insulinActionDuration)

            if  let recentReservoirObjects = try? self.getReservoirObjects(since: continuityStartDate - maximumInterval),
                let oldestRelevantReservoirObject = recentReservoirObjects.last
            {
                // Verify reservoir timestamps are continuous
                self.areReservoirValuesContinuous = InsulinMath.isContinuous(
                    recentReservoirObjects.reversed(),
                    from: continuityStartDate,
                    to: date,
                    within: maximumInterval
                )
                
                // also make sure prime events don't exist withing the Insulin On Board time
                self.primeEventExistsWithinInsulinOnboardTime = getLastPrimeEventDate() >= oldestRelevantReservoirObject.startDate

                return recentReservoirObjects
            }
        }

        self.areReservoirValuesContinuous = false
        self.primeEventExistsWithinInsulinOnboardTime = false
        return []
    }

    /**
     Adds and persists a new reservoir value

     - parameter unitVolume:        The reservoir volume, in units
     - parameter date:              The date of the volume reading
     - parameter completionHandler: A closure called after the value was saved. This closure takes three arguments:
        - value:                    The new reservoir value, if it was saved
        - previousValue:            The last new reservoir value
        - areStoredValuesContinous: Whether the current recent state of the stored reservoir data is considered continuous and reliable for deriving insulin effects after addition of this new value.
        - error:                    An error object explaining why the value could not be saved
     */
    public func addReservoirValue(_ unitVolume: Double, atDate date: Date, completionHandler: @escaping (_ value: ReservoirValue?, _ previousValue: ReservoirValue?, _ areStoredValuesContinuous: Bool, _ error: DoseStoreError?) -> Void) {
        persistenceController.managedObjectContext.perform { [unowned self] in
            let reservoir = Reservoir.insertNewObjectInContext(self.persistenceController.managedObjectContext)

            reservoir.volume = unitVolume
            reservoir.date = date

            var previousValue: Reservoir?
            if let basalProfile = self.basalProfile {
                var newValues: [Reservoir] = []

                previousValue = self.lastReservoirObject

                if let previousValue = previousValue {
                    newValues.append(previousValue)
                }

                newValues.append(reservoir)

                let newDoseEntries = InsulinMath.doseEntriesFromReservoirValues(newValues)

                // Update the understanding of reservoir continuity to warn the caller they might want to try a different data source.
                self.validateReservoirContinuity()

                if self.recentReservoirNormalizedDoseEntriesCache != nil {
                    self.recentReservoirNormalizedDoseEntriesCache = self.recentReservoirNormalizedDoseEntriesCache!.filterDateRange(self.cacheStartDate, nil)

                    self.recentReservoirNormalizedDoseEntriesCache! += InsulinMath.normalize(newDoseEntries, againstBasalSchedule: basalProfile)
                }

                /// Increment the total delivery cache
                if let totalDelivery = self.totalDeliveryCache {
                    self.totalDeliveryCache = InsulinValue(
                        startDate: totalDelivery.startDate,
                        value: totalDelivery.value + InsulinMath.totalDeliveryForDoses(newDoseEntries)
                    )
                }
            }

            self.lastReservoirObject = reservoir

            try? self.purgeReservoirObjects(matching: self.purgeableValuesPredicate)

            self.persistenceController.save { (error) -> Void in
                var saveError: DoseStoreError?

                if let error = error {
                    saveError = .persistenceError(
                        description: error.description,
                        recoverySuggestion: error.recoverySuggestion
                    )
                }

                completionHandler(
                    reservoir,
                    previousValue,
                    self.areReservoirValuesValid,
                    saveError
                )

                NotificationCenter.default.post(name: .DoseStoreValuesDidChange, object: self)
            }
        }
    }

    /**
     Fetches recent reservoir values

     - parameter resultsHandler: A closure called when the results are ready. This closure takes two arguments:
        - objects: An array of reservoir values in reverse-chronological order
        - error:   An error object explaining why the results could not be fetched
     */
    @available(*, deprecated, message: "Use getReservoirValues(since:completionHandler:) instead")
    public func getRecentReservoirValues(_ resultsHandler: @escaping (_ values: [ReservoirValue], _ error: DoseStoreError?) -> Void) {
        guard let startDate = recentValuesStartDate else {
            resultsHandler([], .configurationError)
            return
        }

        getReservoirValues(since: startDate) { (result) in
            switch result {
            case .failure(let error):
                resultsHandler([], error)
            case .success(let values):
                resultsHandler(values, nil)
            }
        }
    }

    /// Retrieves reservoir values since the given date.
    ///
    /// - Parameters:
    ///   - startDate: The earliest reservoir record date to include
    ///   - completionHandler: A closure called after retrieval
    ///   - result: An array of reservoir values in reverse-chronological order
    public func getReservoirValues(since startDate: Date, completionHandler: @escaping (_ result: DoseStoreResult<[ReservoirValue]>) -> Void) {
        persistenceController.managedObjectContext.perform {
            do {
                let objects = try self.getReservoirObjects(since: startDate)

                completionHandler(.success(objects))
            } catch let error as DoseStoreError {
                completionHandler(.failure(error))
            } catch {
                assertionFailure()
            }
        }
    }

    /// *This method should only be called from within a managed object context block.*
    ///
    /// - Parameter startDate: The earliest reservoir record date to include
    /// - Returns: An array of reservoir managed objects, in reverse-chronological order
    /// - Throws: An error describing the failure to fetch objects
    private func getReservoirObjects(since startDate: Date) throws -> [Reservoir] {
        let predicate = NSPredicate(format: "date >= %@", startDate as NSDate)

        do {
            return try Reservoir.objectsInContext(persistenceController.managedObjectContext, predicate: predicate, sortedBy: "date", ascending: false)
        } catch let fetchError as NSError {
            throw DoseStoreError.fetchError(description: fetchError.localizedDescription, recoverySuggestion: fetchError.localizedRecoverySuggestion)
        }
    }

    /// *This method should only be called from within a managed object context block.*
    ///
    /// - Parameter startDate: The earliest dose entry date to include
    /// - Returns: An array of dose entries in chronological order
    /// - Throws: An error describing the failure to fetch reservoir data
    private func getReservoirDoseEntries(since startDate: Date) throws -> [DoseEntry] {
        let objects = try self.getReservoirObjects(since: startDate)

        return InsulinMath.doseEntriesFromReservoirValues(objects.reversed())
    }

    /// Retrieves normalized dose values derived from reservoir readings
    ///
    /// *This method should only be called from within a managed object context block.*
    ///
    /// - Parameters:
    ///   - start: The earliest date of entries to include
    ///   - end: The latest date of entries to include, defaulting to the distant future.
    /// - Returns: An array of normalizd entries
    /// - Throws: A DoseStoreError describing a failure
    private func getNormalizedReservoirDoseEntries(start: Date, end: Date? = nil) throws -> [DoseEntry] {
        if let normalizedDoses = self.recentReservoirNormalizedDoseEntriesCache, let firstDoseDate = normalizedDoses.first?.startDate, firstDoseDate <= start {
            return normalizedDoses.filterDateRange(start, end)
        } else {
            guard let basalProfile = self.basalProfile else {
                throw DoseStoreError.configurationError
            }

            let doses = try self.getReservoirDoseEntries(since: start)

            let normalizedDoses = InsulinMath.normalize(doses, againstBasalSchedule: basalProfile)
            self.recentReservoirNormalizedDoseEntriesCache = normalizedDoses
            return normalizedDoses.filterDateRange(start, end)
        }
    }

    /**
     Deletes a persisted reservoir value

     - parameter value:         The value to delete
     - parameter completion:    A closure called after the value was deleted. This closure takes two arguments:
     - parameter deletedValues: An array of removed values
     - parameter error:         An error object explaining why the value could not be deleted
     */
    public func deleteReservoirValue(_ value: ReservoirValue, completion: @escaping (_ deletedValues: [ReservoirValue], _ error: DoseStoreError?) -> Void) {
        persistenceController.managedObjectContext.perform { [unowned self] in
            var deletedObjects = [Reservoir]()
            if let object = value as? Reservoir {
                self.persistenceController.managedObjectContext.delete(object)
                deletedObjects.append(object)
            }

            self.persistenceController.save { (error) in
                self.clearReservoirNormalizedDoseCache()
                completion(deletedObjects, DoseStoreError(error: error))
                NotificationCenter.default.post(name: .DoseStoreValuesDidChange, object: self)
            }
        }
    }

    /**
     Removes reservoir objects older than the recency predicate

     *This method should only be called from within a managed object context block.*

     - throws: A core data exception if the delete request failed
     */
    private func purgeReservoirObjects(matching predicate: NSPredicate? = nil) throws {
        let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: Reservoir.entityName())
        fetchRequest.predicate = predicate
        let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)

        deleteRequest.resultType = .resultTypeCount

        if let result = try persistenceController.managedObjectContext.execute(deleteRequest) as? NSBatchDeleteResult, let count = result.result as? Int, count > 0 {
            persistenceController.managedObjectContext.refreshAllObjects()
        }
    }

    // MARK: - Pump Event Data

    /// The earliest event date that should included in subsequent queries for pump event data.
    public private(set) var pumpEventQueryAfterDate = Date.distantPast

    /// The last time `addPumpEvents` was called, used to estimate recency of data.
    private var lastAddedPumpEvents = Date.distantPast

    /// The date of the most recent pump prime event, if known.
    /// To to read and check for updates use getLastPrimeEventDate()
    private var _lastRecordedPrimeEventDate: Date?

    /// The last-seen mutable pump events, which aren't persisted but are used for dose calculation.
    private var mutablePumpEventDoses: [DoseEntry]?

    /**
     Adds and persists new pump events.
     
     Events are deduplicated by a unique constraint of pump ID, date, and raw data.

     - parameter events:     An array of new pump events
     - parameter completion: A closure called after the events are saved. The closure takes a single argument:
     - parameter error: An error object explaining why the events could not be saved.
     */
    public func addPumpEvents(_ events: [NewPumpEvent], completion: @escaping (_ error: DoseStoreError?) -> Void) {
        // Consider an empty events array as a successful add
        lastAddedPumpEvents = Date()

        guard events.count > 0 else {
            completion(nil)
            return
        }

        persistenceController.managedObjectContext.perform { [unowned self] in
            var lastFinalDate: Date?
            var firstMutableDate: Date?
            var primeValueAdded = false

            var mutablePumpEventDoses: [DoseEntry] = []

            // There is no guarantee of event ordering, so we must search the entire array to find key date boundaries.
            for event in events {
                if let eventType = event.type {
                    if eventType == .prime {
                        primeValueAdded = true
                    }
                }
                
                if event.isMutable {
                    firstMutableDate = min(event.date, firstMutableDate ?? event.date)

                    if let dose = event.dose {
                        mutablePumpEventDoses.append(dose)
                    }
                } else {
                    lastFinalDate = max(event.date, lastFinalDate ?? event.date)

                    let object = PumpEvent.insertNewObjectInContext(self.persistenceController.managedObjectContext)

                    object.date = event.date
                    object.raw = event.raw
                    object.title = event.title
                    // Generally the type is set from the dose, but in some cases (primes) we do not have a dose
                    object.type = event.type
                    // If dose is nil (as it is in the case of a prime), then nothing will be overwritten by this assignment
                    object.dose = event.dose
                }
            }

            self.mutablePumpEventDoses = mutablePumpEventDoses

            if let mutableDate = firstMutableDate {
                self.pumpEventQueryAfterDate = mutableDate
            } else if let finalDate = lastFinalDate {
                self.pumpEventQueryAfterDate = finalDate
            }

            if primeValueAdded {
                self.invalidateLastPrimeEvent()
                self.validateReservoirContinuity()
            }

            self.persistenceController.save { [unowned self] (error) -> Void in
                completion(DoseStoreError(error: error))
                NotificationCenter.default.post(name: .DoseStoreValuesDidChange, object: self)
                self.uploadPumpEventsIfNeeded()
            }
        }
    }

    public func deletePumpEvent(_ event: PersistedPumpEvent, completion: @escaping (_ error: DoseStoreError?) -> Void) {
        persistenceController.managedObjectContext.perform { [unowned self] in
            if let object = event as? NSManagedObject {
                self.persistenceController.managedObjectContext.delete(object)
            }

            // Reset the latest query date to the newest PumpEvent
            if let lastEvent = PumpEvent.singleObjectInContext(self.persistenceController.managedObjectContext,
                predicate: nil,
                sortedBy: "date",
                ascending: false
            ) {
                self.pumpEventQueryAfterDate = lastEvent.date
            } else {
                self.pumpEventQueryAfterDate = self.recentValuesStartDate ?? .distantPast
            }

            self.persistenceController.save { (error) in
                completion(DoseStoreError(error: error))
                NotificationCenter.default.post(name: .DoseStoreValuesDidChange, object: self)
                
                self.invalidateLastPrimeEvent()
                self.validateReservoirContinuity()
            }
        }
    }

    /**
     Whether there's an outstanding upload request to the delegate.
     
     *This method should only be called from within a managed object context block*
     */
    private var isUploadRequestPending = false

    /**
     Asks the delegate to upload all non-uploaded pump events, and updates the store when the delegate calls its completion handler.

     *This method should only be called from within a managed object context block.*
     */
    private func uploadPumpEventsIfNeeded() {
        guard !isUploadRequestPending, let delegate = delegate else {
            return
        }

        let predicate = NSPredicate(format: "uploaded = false")
        guard let objects = try? PumpEvent.objectsInContext(self.persistenceController.managedObjectContext, predicate: predicate, sortedBy: "date", ascending: true), objects.count > 0 else {
            return
        }

        isUploadRequestPending = true

        delegate.doseStore(self, hasEventsNeedingUpload: objects) { (uploadedObjects) in
            self.persistenceController.managedObjectContext.perform { [unowned self] in
                for id in uploadedObjects {
                    guard let object = try? self.persistenceController.managedObjectContext.existingObject(with: id), let event = object as? PumpEvent else {
                        continue
                    }

                    event.uploaded = true
                }

                // Remove uploaded events older than the
                let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [self.purgeableValuesPredicate,
                                                                                    NSPredicate(format: "uploaded = true")])
                try? self.purgePumpEventObjects(matching: predicate)

                self.persistenceController.save()

                self.isUploadRequestPending = false
            }
        }
    }

    /**
     Fetches recent pump events

     - parameter resultsHandler: A closure called when the results are ready. This closure takes two arguments:
        - values: An array of pump event tuples in reverse-chronological order:
            - title:      A human-readable title describing the event
            - event:      The persisted event data
            - isUploaded: Whether the event has been successfully uploaded by the delegate
        - error:  An error object explaining why the results could not be fetched
     */
    @available(*, deprecated, message: "Use getPumpEventValues(since:completionHandler:) instead")
    public func getRecentPumpEventValues(_ resultsHandler: @escaping (_ values: [(title: String?, event: PersistedPumpEvent, isUploaded: Bool)], _ error: DoseStoreError?) -> Void) {
        guard let startDate = recentValuesStartDate else {
            resultsHandler([], .configurationError)
            return
        }

        getPumpEventValues(since: startDate) { (result) in
            switch result {
            case .failure(let error):
                resultsHandler([], error)
            case .success(let values):
                resultsHandler(values.map({ (title: $0.title, event: $0, isUploaded: $0.isUploaded) }), nil)
            }
        }
    }

    /// Retrieves pump event values since the given date.
    ///
    /// - Parameters:
    ///   - startDate: The earliest pump event date to include
    ///   - completionHandler: A closure called after retrieval
    ///   - result: An array of pump event values in reverse-chronological order
    public func getPumpEventValues(since startDate: Date, completionHandler: @escaping (_ result: DoseStoreResult<[PersistedPumpEvent]>) -> Void) {
        persistenceController.managedObjectContext.perform {
            do {
                let objects: [PersistedPumpEvent] = try self.getPumpEventObjects(since: startDate)

                completionHandler(.success(objects))
            } catch let error as DoseStoreError {
                completionHandler(.failure(error))
            } catch {
                assertionFailure()
            }
        }
    }

    /// *This method should only be called from within a managed object context block.*
    ///
    /// - Parameter startDate: The earliest pump event date to include
    /// - Returns: An array of pump event managed objects, in reverse-chronological order
    /// - Throws: An error describing the failure to fetch objects
    private func getPumpEventObjects(since startDate: Date) throws -> [PumpEvent] {
        return try getPumpEventObjects(
            matching: NSPredicate(format: "date >= %@", startDate as NSDate),
            chronological: false
        )
    }

    /// *This method should only be called from within a managed object context block.*
    ///
    /// - Parameter startDate: The earliest pump event date to include
    /// - Returns: An array of doses from pump events in chronological order
    /// - Throws: An error describing the failure to fetch objects
    private func getPumpEventDoseObjects(since startDate: Date) throws -> [DoseEntry] {
        return try getPumpEventObjects(
            matching: NSPredicate(format: "date >= %@ && type != nil", startDate as NSDate),
            chronological: true
        ).flatMap({ $0.dose })
    }

    /// *This method should only be called from within a managed object context block.*
    ///
    /// - Parameters:
    ///   - predicate: The predicate to apply to the objects
    ///   - chronological: Whether to return the objects in chronological or reverse-chronological order
    /// - Returns: An array of pump events in the specified order by date
    /// - Throws: An error describing the failure to fetch objects
    private func getPumpEventObjects(matching predicate: NSPredicate, chronological: Bool) throws -> [PumpEvent] {
        do {
            return try PumpEvent.objectsInContext(persistenceController.managedObjectContext, predicate: predicate, sortedBy: "date", ascending: chronological)
        } catch let fetchError as NSError {
            throw DoseStoreError.fetchError(description: fetchError.localizedDescription, recoverySuggestion: fetchError.localizedRecoverySuggestion)
        }
    }

    /// *This method should only be called from within a managed object context block.*
    ///
    /// - Parameters:
    ///   - start: The earliest dose end date to include
    ///   - end: The latest dose start date to include
    /// - Returns: An array of doses from pump events
    /// - Throws: An error describing the failure to fetch objects
    private func getNormalizedPumpEventDoseEntries(start: Date, end: Date? = nil) throws -> [DoseEntry] {
        guard let basalProfile = self.basalProfile else {
            throw DoseStoreError.configurationError
        }

        let doses = try getPumpEventDoseObjects(since: start)
        let reconciledDoses = InsulinMath.reconcileDoses(doses + (mutablePumpEventDoses ?? []))
        let normalizedDoses = InsulinMath.normalize(reconciledDoses, againstBasalSchedule: basalProfile)

        return normalizedDoses.filterDateRange(start, end)
    }

    /**
     Removes uploaded pump event objects older than the recency predicate

     *This method should only be called from within a managed object context block.*

     - throws: A core data exception if the delete request failed
     */
    private func purgePumpEventObjects(matching predicate: NSPredicate? = nil) throws {
        let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: PumpEvent.entityName())
        fetchRequest.predicate = predicate

        let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)

        deleteRequest.resultType = .resultTypeCount

        if  let result = try persistenceController.managedObjectContext.execute(deleteRequest) as? NSBatchDeleteResult,
            let count = result.result as? Int,
            count > 0
        {
            persistenceController.managedObjectContext.refreshAllObjects()
        }
    }

    // MARK: - Math

    /**
     *This method should only be called from within a managed object context block.*
     */
    private func clearReservoirCache() {
        validateReservoirContinuity()
        clearReservoirNormalizedDoseCache()
        totalDeliveryCache = nil
        lastReservoirObject = nil
        lastReservoirVolumeDrop = 0
    }

    /**
     *This method should only be called from within a managed object context block.*
     */
    private func clearReservoirNormalizedDoseCache() {
        recentReservoirNormalizedDoseEntriesCache = nil
    }

    /**
     Retrieves recent dose values derived from either pump events or reservoir readings.

     This operation is performed asynchronously and the completion will be executed on an arbitrary background queue.

     - parameter startDate:      The earliest date of entries to retrieve. The default, and earliest supported value, is the earlier of the current date less `insulinActionDuration` or the previous midnight in the current time zone.
     - parameter endDate:        The latest date of entries to retrieve. Defaults to the distant future.
     - parameter resultsHandler: A closure called once the entries have been retrieved. The closure takes two arguments:
        - doses: The retrieved entries
        - error: An error object explaining why the retrieval failed
     */
    @available(*, deprecated, message: "Use getNormalizedDoseEntries(start:end:completion:) instead")
    public func getRecentNormalizedDoseEntries(startDate: Date, endDate: Date? = nil, resultsHandler: @escaping (_ doses: [DoseEntry], _ error: DoseStoreError?) -> Void) {
        getNormalizedDoseEntries(start: startDate, end: endDate) { (result) in
            switch result {
            case .failure(let error):
                resultsHandler([], error)
            case .success(let doses):
                resultsHandler(doses, nil)
            }
        }
    }

    /// Retrieves dose entries normalized to the current basal schedule.
    ///
    /// Doses are derived from pump events if they've been updated within the last 20 minutes or reservoir data is incomplete.
    ///
    /// This operation is performed asynchronously and the completion will be executed on an arbitrary background queue.
    ///
    /// - Parameters:
    ///   - start: The earliest endDate of entries to retrieve
    ///   - end: The latest startDate of entries to retrieve, if provided
    ///   - completion: A closure called once the entries have been retrieved
    ///   - result: An array of dose entries, in chronological order by startDate
    public func getNormalizedDoseEntries(start: Date, end: Date? = nil, completion: @escaping (_ result: DoseStoreResult<[DoseEntry]>) -> Void) {
        persistenceController.managedObjectContext.perform {
            do {
                let doses: [DoseEntry]
                // Reservoir data is used only if its continuous and we haven't seen pump events in the last 20 minutes
                if self.areReservoirValuesValid && self.lastAddedPumpEvents.timeIntervalSinceNow < -TimeInterval(minutes: 20) {
                    doses = try self.getNormalizedReservoirDoseEntries(start: start, end: end)
                } else {
                    doses = try self.getNormalizedPumpEventDoseEntries(start: start, end: end)
                }

                completion(.success(doses))
            } catch let error as DoseStoreError {
                completion(.failure(error))
            } catch {
                assertionFailure()
            }
        }
    }

    /**
     Retrieves the most recent unabsorbed insulin value relative to the specified date
     
     - parameter date:          The date of the value to retrieve.
     - parameter resultHandler: A closure called once the value has been retrieved. The closure takes two arguemnts:
        - value: The retrieved value
        - error: An error object explaining why the retrieval failed
     */
    @available(*, deprecated, message: "Use insulinOnBoard(at:completionHandler:) instead")
    public func insulinOnBoardAtDate(_ date: Date, resultHandler: @escaping (_ value: InsulinValue?, _ error: Error?) -> Void) {
        insulinOnBoard(at: date) { (result) in
            switch result {
            case .failure(let error):
                resultHandler(nil, error)
            case .success(let value):
                resultHandler(value, nil)
            }
        }
    }

    /// Retrieves the single insulin on-board value occuring just prior to the specified date
    ///
    /// This operation is performed asynchronously and the completion will be executed on an arbitrary background queue.
    ///
    /// - Parameters:
    ///   - date: The date of the value to retrieve
    ///   - completionHandler: A closure called once the value has been retrieved
    ///   - result: The insulin on-board value
    public func insulinOnBoard(at date: Date, completionHandler: @escaping (_ result: DoseStoreResult<InsulinValue>) -> Void) {
        getInsulinOnBoardValues(start: date.addingTimeInterval(TimeInterval(minutes: -5))) { (result) -> Void in
            switch result {
            case .failure(let error):
                completionHandler(.failure(error))
            case .success(let values):
                guard let value = values.closestPriorToDate(date) else {
                    completionHandler(.failure(.fetchError(description: "No values found", recoverySuggestion: "Ensure insulin data exists for the specified date")))
                    return
                }
                completionHandler(.success(value))
            }
        }
    }

    /**
     Retrieves a timeline of unabsorbed insulin values.

     This operation is performed asynchronously and the completion will be executed on an arbitrary background queue.

     - parameter startDate:     The earliest date of values to retrieve. The earliest supported value is the previous midnight in the current time zone.
     - parameter endDate:       The latest date of values to retrieve. Defaults to the distant future.
     - parameter resultHandler: A closure called once the values have been retrieved. The closure takes two arguments:
        - values: The retrieved values
        - error:  An error object explaining why the retrieval failed
     */
    @available(*, deprecated, message: "Use getInsulinOnBoardValues(start:end:completionHandler:) instead")
    public func getInsulinOnBoardValues(startDate: Date, endDate: Date? = nil, resultHandler: @escaping (_ values: [InsulinValue], _ error: DoseStoreError?) -> Void) {
        getInsulinOnBoardValues(start: startDate, end: endDate) { (result) in
            switch result {
            case .failure(let error):
                resultHandler([], error)
            case .success(let iob):
                resultHandler(iob, nil)
            }
        }
    }

    /// Retrieves a timeline of unabsorbed insulin values.
    ///
    /// This operation is performed asynchronously and the completion will be executed on an arbitrary background queue.
    ///
    /// - Parameters:
    ///   - start: The earliest date of values to retrieve
    ///   - end: The latest date of values to retrieve, if provided
    ///   - basalDosingEnd: The date at which continuing doses should be assumed to be cancelled
    ///   - completionHandler: A closure called once the values have been retrieved
    ///   - result: An array of insulin values, in chronological order
    public func getInsulinOnBoardValues(start: Date, end: Date? = nil, basalDosingEnd: Date? = nil,completionHandler: @escaping (_ result: DoseStoreResult<[InsulinValue]>) -> Void) {
        guard let insulinActionDuration = self.insulinActionDuration else {
            completionHandler(.failure(.configurationError))
            return
        }

        // To properly know IOB at startDate, we need to go back another DIA hours
        let doseStart = start.addingTimeInterval(-insulinActionDuration)
        getNormalizedDoseEntries(start: doseStart, end: end) { (result) in
            switch result {
            case .failure(let error):
                completionHandler(.failure(error))
            case .success(let doses):
                let trimmedDoses = InsulinMath.trimContinuingDoses(doses, endDate: basalDosingEnd)
                let insulinOnBoard = InsulinMath.insulinOnBoardForDoses(trimmedDoses, actionDuration: insulinActionDuration)
                completionHandler(.success(insulinOnBoard.filterDateRange(start, end)))
            }
        }
    }

    /**
     Retrieves a timeline of effect on blood glucose from doses

     This operation is performed asynchronously and the completion will be executed on an arbitrary background queue.

     - parameter startDate:     The earliest date of effects to retrieve. The earliest supported value is the previous midnight in the current time zone.
     - parameter endDate:       The latest date of effects to retrieve. Defaults to the distant future.
     - parameter resultHandler: A closure called once the effects have been retrieved. The closure takes two arguments:
        - effects: The retrieved timeline of effects
        - error:   An error object explaining why the retrieval failed
     */
    @available(*, deprecated, message: "Use getGlucoseEffects(start:end:completionHandler:) instead")
    public func getGlucoseEffects(startDate: Date, endDate: Date? = nil, resultHandler: @escaping (_ effects: [GlucoseEffect], _ error: DoseStoreError?) -> Void) {
        getGlucoseEffects(start: startDate, end: endDate) { (result) in
            switch result {
            case .failure(let error):
                resultHandler([], error)
            case .success(let effects):
                resultHandler(effects, nil)
            }
        }
    }

    /// Retrieves a timeline of effect on blood glucose from doses
    ///
    /// This operation is performed asynchronously and the completion will be executed on an arbitrary background queue.
    ///
    /// - Parameters:
    ///   - start: The earliest date of effects to retrieve
    ///   - end: The latest date of effects to retrieve, if provided
    ///   - basalDosingEnd: The date at which continuing doses should be assumed to be cancelled
    ///   - completionHandler: A closure called once the effects have been retrieved
    ///   - result: An array of effects, in chronological order
    public func getGlucoseEffects(start: Date, end: Date? = nil, basalDosingEnd: Date? = Date(), completionHandler: @escaping (_ result: DoseStoreResult<[GlucoseEffect]>) -> Void) {
        guard let insulinActionDuration = self.insulinActionDuration,
              let insulinSensitivitySchedule = self.insulinSensitivitySchedule
        else {
            completionHandler(.failure(.configurationError))
            return
        }

        // To properly know glucose effects at startDate, we need to go back another DIA hours
        let doseStart = start.addingTimeInterval(-insulinActionDuration)
        getNormalizedDoseEntries(start: doseStart, end: end) { (result) in
            switch result {
            case .failure(let error):
                completionHandler(.failure(error))
            case .success(let doses):
                let trimmedDoses = InsulinMath.trimContinuingDoses(doses, endDate: basalDosingEnd)
                let glucoseEffects = InsulinMath.glucoseEffectsForDoses(trimmedDoses, actionDuration: insulinActionDuration, insulinSensitivity: insulinSensitivitySchedule)
                completionHandler(.success(glucoseEffects.filterDateRange(start, end)))
            }
        }
    }

    /**
     Retrieves the estimated total number of units delivered for a default time period: the current day.

     This operation is performed asynchronously and the completion will be executed on an arbitrary background queue.

     - parameter resultsHandler: A closure called once the total has been retrieved. The closure takes three arguments:
     - parameter total: The retrieved value
     - parameter since: The earliest date included in the total
     - parameter error: An error object explaining why the retrieval failed
     */
    @available(*, deprecated, message: "Use getTotalUnitsDelivered(since:completionHandler:)")
    public func getTotalRecentUnitsDelivered(_ resultsHandler: @escaping (_ total: Double, _ since: Date?, _ error: DoseStoreError?) -> Void) {
        guard let startDate = recentValuesStartDate else {
            resultsHandler(0, nil, DoseStoreError.configurationError)
            return
        }

        getTotalUnitsDelivered(since: startDate) { (result) in
            switch result {
            case .failure(let error):
                resultsHandler(0, nil, error)
            case .success(let result):
                resultsHandler(result.value, result.startDate, nil)
            }
        }
    }

    /// Retrieves the estimated total number of units delivered since the specified date.
    ///
    /// - Parameters:
    ///   - startDate: The date after which delivery should be calculated
    ///   - completionHandler: A closure called once the total has been retrieved with arguments:
    ///   - result: The total units delivered and the date of the first dose
    public func getTotalUnitsDelivered(since startDate: Date, completionHandler: @escaping (_ result: DoseStoreResult<InsulinValue>) -> Void) {
        persistenceController.managedObjectContext.perform {
            if  let totalDeliveryCache = self.totalDeliveryCache,
                totalDeliveryCache.startDate >= startDate
            {
                completionHandler(.success(totalDeliveryCache))
                return
            }

            do {
                let doses = try self.getReservoirDoseEntries(since: startDate)
                let result = InsulinValue(
                    startDate: doses.first?.startDate ?? Date(),
                    value: InsulinMath.totalDeliveryForDoses(doses)
                )

                if doses.count > 0 {
                    self.totalDeliveryCache = result
                }

                completionHandler(.success(result))
            } catch let error as DoseStoreError {
                completionHandler(.failure(error))
            } catch {
                assertionFailure()
            }
        }
    }

    /// Generates a diagnostic report about the current state
    ///
    /// This operation is performed asynchronously and the completion will be executed on an arbitrary background queue.
    ///
    /// - parameter completionHandler: The closure takes a single argument of the report string.
    public func generateDiagnosticReport(_ completionHandler: @escaping (_ report: String) -> Void) {
        var report: [String] = [
            "## DoseStore",
            "",
            "* readyState: \(readyState)",
            "* insulinActionDuration: \(insulinActionDuration ?? 0)",
            "* basalProfile: \(basalProfile?.debugDescription ?? "")",
            "* insulinSensitivitySchedule: \(insulinSensitivitySchedule?.debugDescription ?? "")",
            "* areReservoirValuesContinuous: \(areReservoirValuesContinuous)",
            "* primeEventExistsWithinInsulinOnboardTime: \(primeEventExistsWithinInsulinOnboardTime)",
            "* totalDeliveryCache: \(String(describing: totalDeliveryCache))",
            "* lastPrimeEventDate: \(String(describing: _lastRecordedPrimeEventDate))",
        ]

        getReservoirValues(since: Date.distantPast) { (result) in
            report.append("")
            report.append("### getReservoirValues")

            switch result {
            case .failure(let error):
                report.append("Error: \(error)")
            case .success(let values):
                report.append("")
                for value in values {
                    report.append("* \(value.startDate), \(value.unitVolume)")
                }
            }

            self.getPumpEventValues(since: Date.distantPast) { (result) in
                report.append("")
                report.append("### getRecentPumpEventValues")

                switch result {
                case .failure(let error):
                    report.append("Error: \(error)")
                case .success(let values):
                    report.append("")
                    for value in values {
                        report.append("* \(value)")
                    }
                }

                self.getNormalizedDoseEntries(start: Date.distantPast) { (result) in
                    report.append("")
                    report.append("### getNormalizedDoseEntries")

                    switch result {
                    case .failure(let error):
                        report.append("Error: \(error)")
                    case .success(let entries):
                        report.append("")
                        for entry in entries {
                            report.append("* \(entry)")
                        }
                    }

                    report.append("")
                    completionHandler(report.joined(separator: "\n"))
                }
            }
        }
    }
    
    /// Flag the existing last prime event date as invalid
    private func invalidateLastPrimeEvent() {
        _lastRecordedPrimeEventDate = nil
    }
    
    /// Get the date of the last prime event. Updates from CoreData if value is invalid
    ///
    /// - Returns: Date of the last Prime Event, or nil if none found
    private func getLastPrimeEventDate() -> Date {
        if _lastRecordedPrimeEventDate == nil {
            if let pumpEvents = try? self.getPumpEventObjects(
                matching: NSPredicate(format: "type = %@", PumpEventType.prime.rawValue),
                chronological: false
                ),
                let firstEvent = pumpEvents.first {
                _lastRecordedPrimeEventDate =  firstEvent.date
            } else {
                _lastRecordedPrimeEventDate = Date.distantPast
            }
        }
        
        return _lastRecordedPrimeEventDate ?? Date.distantPast
    }
}

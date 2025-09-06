
import Combine
import Foundation
import G7SensorKit
import LoopKit
import LoopKitUI

final class DexcomSourceG7: GlucoseSource {
    private let processQueue = DispatchQueue(label: "DexcomSource.processQueue")
    private var glucoseStorage: GlucoseStorage!
    var glucoseManager: FetchGlucoseManager?

    var cgmManager: CGMManagerUI?
    var cgmType: CGMType = .dexcomG7
    var cgmHasValidSensorSession: Bool = false

    private var promise: Future<[BloodGlucose], Error>.Promise?

    init(glucoseStorage: GlucoseStorage, glucoseManager: FetchGlucoseManager) {
        self.glucoseStorage = glucoseStorage
        self.glucoseManager = glucoseManager
        cgmManager = G7CGMManager()
        cgmManager?.cgmManagerDelegate = self
        cgmManager?.delegateQueue = processQueue

        // initial value of upload Readings
        if let cgmManagerG7 = cgmManager as? G7CGMManager {
            cgmManagerG7.uploadReadings = glucoseManager.settingsManager.settings.uploadGlucose
            debug(.deviceManager, "DEXCOMG7 - Initialized G7CGMManager with uploadReadings: \(cgmManagerG7.uploadReadings)")
        }
    }

    func fetch(_: DispatchTimer?) -> AnyPublisher<[BloodGlucose], Never> {
        Future<[BloodGlucose], Error> { [weak self] promise in
            self?.promise = promise
        }
        .timeout(60 * 5, scheduler: processQueue, options: nil, customError: nil)
        .replaceError(with: [])
        .replaceEmpty(with: [])
        .eraseToAnyPublisher()
    }

    func fetchIfNeeded() -> AnyPublisher<[BloodGlucose], Never> {
        Future<[BloodGlucose], Error> { _ in
            self.processQueue.async {
                guard let cgmManager = self.cgmManager else { return }
                cgmManager.fetchNewDataIfNeeded { result in
                    self.processCGMReadingResult(cgmManager, readingResult: result) {
                        // nothing to do
                    }
                }
            }
        }
        .timeout(60, scheduler: processQueue, options: nil, customError: nil)
        .replaceError(with: [])
        .replaceEmpty(with: [])
        .eraseToAnyPublisher()
    }

    deinit {
        // dexcomManager.transmitter.stopScanning()
    }
}

extension DexcomSourceG7: CGMManagerDelegate {
    func deviceManager(
        _: LoopKit.DeviceManager,
        logEventForDeviceIdentifier deviceIdentifier: String?,
        type _: LoopKit.DeviceLogEntryType,
        message: String,
        completion _: ((Error?) -> Void)?
    ) {
        debug(.deviceManager, "device Manager for \(String(describing: deviceIdentifier)) : \(message)")
    }

    func issueAlert(_: LoopKit.Alert) {}

    func retractAlert(identifier _: LoopKit.Alert.Identifier) {}

    func doesIssuedAlertExist(identifier _: LoopKit.Alert.Identifier, completion _: @escaping (Result<Bool, Error>) -> Void) {}

    func lookupAllUnretracted(
        managerIdentifier _: String,
        completion _: @escaping (Result<[LoopKit.PersistedAlert], Error>) -> Void
    ) {}

    func lookupAllUnacknowledgedUnretracted(
        managerIdentifier _: String,
        completion _: @escaping (Result<[LoopKit.PersistedAlert], Error>) -> Void
    ) {}

    func recordRetractedAlert(_: LoopKit.Alert, at _: Date) {}

    func cgmManagerWantsDeletion(_ manager: CGMManager) {
        dispatchPrecondition(condition: .onQueue(processQueue))
        debug(.deviceManager, " CGM Manager with identifier \(manager.managerIdentifier) wants deletion")
        glucoseManager?.cgmGlucoseSourceType = nil
    }

    func cgmManager(_ manager: CGMManager, hasNew readingResult: CGMReadingResult) {
        dispatchPrecondition(condition: .onQueue(processQueue))
        debug(.deviceManager, "DEXCOMG7 - cgmManager hasNew called with result type: \(String(describing: readingResult))")
        processCGMReadingResult(manager, readingResult: readingResult) {
            debug(.deviceManager, "DEXCOMG7 - Direct return done")
        }
    }

    func startDateToFilterNewData(for _: CGMManager) -> Date? {
        dispatchPrecondition(condition: .onQueue(processQueue))
        let lastGlucoseDate = glucoseStorage.lastGlucoseDate()
        debug(.deviceManager, "DEXCOMG7 - startDateToFilterNewData: \(String(describing: lastGlucoseDate))")
        
        // Allow backfilled data by extending the filter date back further
        // This ensures backfilled data from sensor reconnections is not filtered out
        if let lastDate = lastGlucoseDate {
            let extendedDate = lastDate.addingTimeInterval(-3600) // Allow 1 hour of backfill
            debug(.deviceManager, "DEXCOMG7 - Extended filter date for backfill: \(extendedDate)")
            return extendedDate
        }
        return lastGlucoseDate
    }

    func cgmManagerDidUpdateState(_ cgmManager: CGMManager) {
        if let cgmManagerG7 = cgmManager as? G7CGMManager {
            glucoseManager?.settingsManager.settings.uploadGlucose = cgmManagerG7.uploadReadings
        }
    }

    func credentialStoragePrefix(for _: CGMManager) -> String {
        // return string unique to this instance of the CGMManager
        UUID().uuidString
    }

    func cgmManager(_: CGMManager, didUpdate status: CGMManagerStatus) {
        processQueue.async {
            if self.cgmHasValidSensorSession != status.hasValidSensorSession {
                self.cgmHasValidSensorSession = status.hasValidSensorSession
            }
        }
    }

    private func processCGMReadingResult(
        _: CGMManager,
        readingResult: CGMReadingResult,
        completion: @escaping () -> Void
    ) {
        debug(.deviceManager, "DEXCOMG7 - Process CGM Reading Result launched")
        switch readingResult {
        case let .newData(values):
            debug(.deviceManager, "DEXCOMG7 - Received \(values.count) new glucose values")

            var activationDate: Date = .distantPast
            var sessionStart: Date = .distantPast
            if let cgmG7Manager = cgmManager as? G7CGMManager {
                activationDate = cgmG7Manager.sensorActivatedAt ?? .distantPast
                sessionStart = cgmG7Manager.sensorFinishesWarmupAt ?? .distantPast
                debug(.deviceManager, "DEXCOMG7 - Activation date: \(activationDate)")
            }

            let bloodGlucose = values.compactMap { newGlucoseSample -> BloodGlucose? in
                let quantity = newGlucoseSample.quantity
                let value = Int(quantity.doubleValue(for: .milligramsPerDeciliter))
                
                debug(.deviceManager, "DEXCOMG7 - Processing glucose: \(value) mg/dL at \(newGlucoseSample.date), isDisplayOnly: \(newGlucoseSample.isDisplayOnly), wasUserEntered: \(newGlucoseSample.wasUserEntered)")
                
                return BloodGlucose(
                    _id: UUID().uuidString,
                    sgv: value,
                    direction: .init(trendType: newGlucoseSample.trend),
                    date: Decimal(Int(newGlucoseSample.date.timeIntervalSince1970 * 1000)),
                    dateString: newGlucoseSample.date,
                    unfiltered: Decimal(value),
                    filtered: nil,
                    noise: nil,
                    glucose: value,
                    type: "sgv",
                    activationDate: activationDate,
                    sessionStartDate: sessionStart
                )
            }

            debug(.deviceManager, "DEXCOMG7 - Processed \(bloodGlucose.count) blood glucose readings")
            promise?(.success(bloodGlucose))

            completion()
        case .unreliableData:
            // loopManager.receivedUnreliableCGMReading()
            debug(.deviceManager, "DEXCOMG7 - Received unreliable data")
            promise?(.failure(GlucoseDataError.unreliableData))
            completion()
        case .noData:
            debug(.deviceManager, "DEXCOMG7 - No data received")
            promise?(.failure(GlucoseDataError.noData))
            completion()
        case let .error(error):
            debug(.deviceManager, "DEXCOMG7 - Error received: \(error)")
            promise?(.failure(error))
            completion()
        }
    }
}

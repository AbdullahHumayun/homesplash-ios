import BackgroundTasks
import SwiftUI
import UIKit

@main
struct HomesplashApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(HealthSync.shared)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await HealthSync.shared.syncIfDue(minInterval: 60) }
            } else if phase == .background {
                BackgroundSync.schedule()
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Both must be set up at launch so iOS can wake the app in the background.
        BackgroundSync.register()
        HealthSync.shared.startObservers()
        return true
    }
}

enum BackgroundSync {
    static let taskID = "com.abdullahhumayun.homesplash.refresh"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            schedule()  // always queue the next one
            let work = Task { @MainActor in
                await HealthSync.shared.syncIfDue(minInterval: 5 * 60)
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

import Foundation
import CoreGraphics
import AppKit
import ApplicationServices

// MARK: - CGS private API (for cross-Space window activation)

typealias CGSConnectionID = UInt32
typealias CGSSpaceID = UInt64

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

/// Returns the space IDs for the given window IDs. mask 7 = all spaces.
@_silgen_name("CGSCopySpacesForWindows")
func CGSCopySpacesForWindows(_ cid: CGSConnectionID, _ mask: Int, _ wids: CFArray) -> CFArray

/// Returns an array of display dictionaries, each with a "Spaces" array and "Display Identifier".
@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> CFArray

/// Switches the active space on the given display to sid. No slide animation.
@_silgen_name("CGSManagedDisplaySetCurrentSpace")
func CGSManagedDisplaySetCurrentSpace(_ cid: CGSConnectionID, _ display: CFString, _ sid: CGSSpaceID) -> Void

/// Removes browser window from the list of windows and adds tabs to the results array
func searchBrowserTabsIfNeeded(processName: String,
                               windows: [WindowInfoDict],
                               query: String,
                               results: inout [[AlfredItem]]) -> [WindowInfoDict] {
    
    let activeWindowsExceptBrowser = windows.filter { ($0.processName != processName) }
    
    let browserTabs =
        BrowserApplication.connect(processName: processName)?.windows
            .flatMap { return $0.tabs }
            .search(query: query)
    
    results.append(browserTabs ?? [])
    
    return activeWindowsExceptBrowser
}

func search(query: String, onlyTabs: Bool) {
    var results : [[AlfredItem]] = []
    
    var allActiveWindows : [WindowInfoDict] = Windows.all
    
    for browserName in ["Safari", "Safari Technology Preview",
                        "Google Chrome", "Google Chrome Canary",
                        "Opera", "Opera Beta", "Opera Developer",
                        "Brave Browser", "iTerm"] {
        allActiveWindows = searchBrowserTabsIfNeeded(processName: browserName,
                                                     windows: allActiveWindows,
                                                     query: query,
                                                     results: &results) // inout!
    }
    
    if !onlyTabs {
        results.append(allActiveWindows.search(query: query))
    }
    
    let alfredItems : [AlfredItem] = results.flatMap { $0 }

    print(AlfredDocument(withItems: alfredItems).xml.xmlString)
}

func activate(arg: String) {
    let parts = arg.components(separatedBy: "|||||")
    guard !parts.isEmpty else { return }
    let windowId = parts.count > 3 ? UInt32(parts[3]) ?? 0 : 0

    if windowId > 0 {
        // Look up app by PID from CGWindowListCopyWindowInfo — same data source as the
        // search step, and unambiguous unlike localizedName vs kCGWindowOwnerName.
        let allWindows = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []
        let windowInfo = allWindows.first {
            ($0[kCGWindowNumber as String] as? UInt32) == windowId
        }
        guard let ownerPid = windowInfo?[kCGWindowOwnerPID as String] as? pid_t,
              let app = NSWorkspace.shared.runningApplications
                  .first(where: { $0.processIdentifier == ownerPid })
        else { return }

        // Get window title for AX matching (AXWindowID fails with -25205 after space switch).
        let targetTitle = windowInfo?[kCGWindowName as String] as? String ?? ""

        let cid = CGSMainConnectionID()

        // Find which space this window lives on (mask 7 = all spaces).
        let spaceIds = CGSCopySpacesForWindows(cid, 7, [windowId] as CFArray) as! [CGSSpaceID]
        if let targetSpaceId = spaceIds.first {
            // Find the display UUID that owns this space.
            var targetDisplay: CFString? = nil
            let displaySpaces = CGSCopyManagedDisplaySpaces(cid) as! [[String: Any]]
            outer: for screen in displaySpaces {
                guard let spaces = screen["Spaces"] as? [[String: Any]] else { continue }
                for space in spaces {
                    if let sid = space["id64"] as? CGSSpaceID, sid == targetSpaceId {
                        var display = screen["Display Identifier"] as! CFString
                        // "Main" is a sentinel on single-display setups — map to real UUID.
                        if (display as String) == "Main" {
                            if let mainScreen = NSScreen.main,
                               let screenNumber = mainScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                               let uuidRef = CGDisplayCreateUUIDFromDisplayID(screenNumber) {
                                display = CFUUIDCreateString(nil, uuidRef.takeRetainedValue())!
                            }
                        }
                        targetDisplay = display
                        break outer
                    }
                }
            }

            // Switch to the target space (no slide animation, but space does change).
            if let display = targetDisplay {
                CGSManagedDisplaySetCurrentSpace(cid, display, targetSpaceId)
                // Wait for the space context to propagate before AX queries.
                Thread.sleep(forTimeInterval: 0.5)
            }
        }

        // Activate the app, then AXRaise the specific window.
        app.activate(options: [.activateIgnoringOtherApps])
        Thread.sleep(forTimeInterval: 0.3)

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let windows = windowsRef as? [AXUIElement] {
            for window in windows {
                // Match by title instead of AXWindowID (which fails with -25205 after space switch).
                var titleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
                   let axTitle = titleRef as? String,
                   axTitle == targetTitle, !targetTitle.isEmpty {
                    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                    break
                }
            }
        }
        return
    }

    // Fallback: no windowId, activate by processName.
    let processName = parts[0]
    guard let app = NSWorkspace.shared.runningApplications
        .first(where: { $0.localizedName == processName }) else { return }
    app.activate(options: [.activateIgnoringOtherApps])
}

func handleCatalinaScreenRecordingPermission() {
    guard let firstWindow = Windows.any else {
        return
    }

    guard !firstWindow.hasName else {
        return
    }

    #if !os(macOS) || swift(<5.9)
    let windowImage = CGWindowListCreateImage(.null, .optionIncludingWindow,
                                              firstWindow.number,
                                              [.boundsIgnoreFraming, .bestResolution])
    if windowImage == nil {
        debugPrint("Before using this app, you need to give permission in System Preferences > Security & Privacy > Privacy > Screen Recording.\nPlease authorize and re-launch.")
        exit(1)
    }
    #else
    // On macOS 15+, CGWindowListCreateImage is unavailable; the OS handles Screen Recording permission prompts automatically.
    debugPrint("Before using this app, you need to give permission in System Preferences > Security & Privacy > Privacy > Screen Recording.\nPlease authorize and re-launch.")
    exit(1)
    #endif
}

NSApplication.shared.setActivationPolicy(.accessory)

handleCatalinaScreenRecordingPermission()

/*
 a naive perf test, decided to keep it here for convenience

let start = DispatchTime.now() // <<<<<<<<<< Start time

for _ in 0...100 {
    search(query: "pull", onlyTabs: false)
}
let end = DispatchTime.now()   // <<<<<<<<<<   end time
let nanoTime = end.uptimeNanoseconds - start.uptimeNanoseconds // <<<<< Difference in nano seconds (UInt64)
let timeInterval = Double(nanoTime) / 1_000_000_000 // Technically could overflow for long running tests

print("TIME SPENT: \(timeInterval)")
*/

if(CommandLine.commands().isEmpty) {
    print("Unknown command!")
    print("Commands:")
    print("--search=<query> to search for active windows/Safari tabs.")
    print("--search-tabs=<query> to search for active browser tabs.")
    exit(1)
}

for command in CommandLine.commands() {
    switch command {
    case let searchCommand as SearchCommand:
        search(query: searchCommand.query, onlyTabs: false)
        exit(0)
    case let searchCommand as OnlyTabsCommand:
        search(query: searchCommand.query, onlyTabs: true)
        exit(0)
    case let activateCommand as ActivateCommand:
        activate(arg: activateCommand.query)
        exit(0)
    default:
        print("Unknown command!")
        print("Commands:")
        print("--search=<query> to search for active windows/Safari tabs.")
        print("--search-tabs=<query> to search for active browser tabs.")
        exit(1)
    }
    
}

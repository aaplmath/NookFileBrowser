//
//  DiskManager.swift
//  NookFileBrowser
//
//  Created by aaplmath on 3/18/20.
//  Copyright © 2020 aaplmath. All rights reserved.
//

import Foundation
import Combine

extension String {
    var escapedForQuotedString: String {
        get {
            self.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
    }
}

class DiskManager : ObservableObject {
    struct Entity : Identifiable {
        enum ObjectType {
            case directory
            case file
        }
        
        var id: String {
            return String(type.hashValue) + name
        }
        
        var name: String
        var type: ObjectType
        var hidden: Bool
    }
    
    @Published var contents = [Entity]()
    @Published var loadFailure: Bool = false
    @Published var isPendingError: Bool = false {
        didSet {
            if !isPendingError {
                pendingErrorMessage = nil
            }
        }
    }
    
    var pendingErrorMessage: String? = nil {
        didSet {
            if pendingErrorMessage != nil {
                DispatchQueue.main.async {
                    self.isPendingError = true
                }
            }
        }
    }
    
    private var cancellable: AnyCancellable!
    private var buffer: String = ""
    private var activeProc: Process! // only ever allow there to be one active process—having multiple concurrent fetches is wasteful and will lead to a race condition when writing to contents

    @Published var pwd: String = "" {
        willSet(pwd) {
            guard pwd != self.pwd else {
                // Avoid re-fetching the same directory (most commonly, when attempting to traverse up from root)
                return
            }
            updateFileList(for: pwd)
        }
    }
    
    init() {
        pwd = Constants.homePath // since didSet doesn't get called on first init and the value needs to change to refresh (a bit hacky…)
    }
    
    private func updateFileList(for pwd: String) {
        if let oldProc = activeProc, oldProc.isRunning {
            oldProc.terminate()
        }
        activeProc = Process()
        activeProc.executableURL = Constants.adbURL
        let safePwd = pwd.escapedForQuotedString // in case the pwd has quotation marks in its name
        activeProc.arguments = ["shell", #"for f in "\#(safePwd)"/{.,}*; do if [[ -e "$f" ]]; then if [[ -d "$f" ]]; then echo -n "d"; else echo -n "f"; fi; busybox basename "$f"; fi; done"#]
        
        let outPipe = Pipe()
        activeProc.standardOutput = outPipe
        let outPipeHandle = outPipe.fileHandleForReading
        
        activeProc.terminationHandler = { proc in
            // If the process did not succeed and was not terminated prematurely (i.e., because the user changed directories before loading could complete), display an error message—most likely, the device is not connected
            if proc.terminationStatus != 0 && proc.terminationStatus != SIGTERM {
                DispatchQueue.main.async {
                    self.loadFailure = true
                }
            }
        }
        
        buffer = ""
        outPipeHandle.readabilityHandler = { fileHandle in
            // We need to capture a single snapshot of availableData to use throughout the closure, since availableData will keep populating as we execute
            let data = fileHandle.availableData
            if data.isEmpty {
                // Make sure to deregister when we receive EOF; otherwise, this handler will be called endlessly
                outPipeHandle.readabilityHandler = nil
            } else if let line = String(data: data, encoding: .utf8) {
                self.buffer += line
                let entities = self.buffer.split(separator: "\r\n")
                if !entities.isEmpty {
                    let validEntities: [Substring]
                    if self.buffer.count > 1 && self.buffer.lastIndex(of: "\r\n") == self.buffer.index(before: self.buffer.endIndex) {
                        // If we hit an update right at the end of a file (or it's the end of the list), we can do a complete sweep and flush the buffer
                        validEntities = entities
                        self.buffer = ""
                    } else {
                        // Updates will likely occur in the middle of a line/entity, so the last element of the buffer is still in progress if it doesn't have the correct terminator
                        validEntities = entities.dropLast()
                        self.buffer = String(entities.last ?? "")
                    }
                    DispatchQueue.main.async {
                        self.contents.append(contentsOf:
                            validEntities
                                .filter { $0 != "d." && $0 != "d.." } // ignore the "." and ".." directories
                                .map { Entity(name: String($0.dropFirst()),
                                              type: $0.first == "d" ? .directory : .file,
                                              hidden: $0.dropFirst().first == ".") }
                        )
                    }
                }
            } else {
                self.showError("Error decoding file list output data: \(data)")
            }
        }
        
        contents = []
        loadFailure = false
        runAndCatch(activeProc, withErrDesc: "Error running adb to fetch files. The most likely cause of this error is that you have not installed the adb command-line tool, or it is not installed at /usr/local/bin/adb. Further details are provided for reference:")
    }
    
    func forceRefreshFilesList() {
        updateFileList(for: pwd)
    }
    
    func downloadFile(path: String) {
        let dlDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path
        guard dlDir != "" else {
            showError("Could not find user Downloads directory")
            return
        }
        let dlProc = Process()
        dlProc.executableURL = Constants.adbURL
        dlProc.arguments = ["pull", path, dlDir]
        runAndCatch(dlProc, withErrDesc: "Error downloading file")
        dlProc.terminationHandler = { terminatedProc in
            if terminatedProc.terminationStatus == 0 {
                let filename = path.components(separatedBy: "/").last ?? path
                DistributedNotificationCenter.default.post(name: NSNotification.Name(rawValue: "com.apple.DownloadFileFinished"), object: "\(dlDir)/\(filename)", userInfo: nil)
            } else {
                self.showError("Failed to download file with termination status \(terminatedProc.terminationStatus)")
            }
        }
    }
    
    func uploadFiles(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(kUTTypeFileURL as String) {
                provider.loadItem(forTypeIdentifier: kUTTypeFileURL as String, options: nil) { item, err in
                    guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else {
                        return
                    }
                    let localFilePath = url.path
                    
                    let uploadProc = Process()
                    uploadProc.executableURL = Constants.adbURL
                    uploadProc.arguments = ["push", localFilePath, Constants.uploadPath]
                    self.runAndCatch(uploadProc, withErrDesc: "Error uploading file")
                    
                    uploadProc.terminationHandler = { uploadProc in
                        guard uploadProc.terminationStatus == 0 else {
                            self.showError("Upload process failed with status \(uploadProc.terminationStatus)")
                            return
                        }
                        self.runSyncBroadcastAndRefresh()
                    }
                }
            }
        }
    }
    
    func deleteFile(path: String) {
        let rmProc = Process()
        rmProc.executableURL = Constants.adbURL
        rmProc.arguments = ["shell", "rm", "-r", "\"\(path.escapedForQuotedString)\""]
        runAndCatch(rmProc, withErrDesc: "Error executing rm over adb")
        
        rmProc.terminationHandler = { terminatedProc in
            self.runSyncBroadcastAndRefresh()
        }
    }
    
    private func runSyncBroadcastAndRefresh() {
        let broadcastProc = Process()
        broadcastProc.executableURL = Constants.adbURL
        broadcastProc.arguments = ["shell", "am", "broadcast", "-a", "android.intent.action.MEDIA_MOUNTED", "-d", Constants.storageRootURL]
        runAndCatch(broadcastProc, withErrDesc: "Error sending broadcast")
        
        DispatchQueue.main.async {
            self.updateFileList(for: self.pwd)
        }
    }
    
    private func runAndCatch(_ process: Process, withErrDesc errDesc: String) {
        do {
            try process.run()
        } catch let e {
            showError("\(errDesc)\t\(e.localizedDescription)\n\n\(e)")
            return
        }
    }
    
    private func showError(_ message: String) {
        pendingErrorMessage = message
    }
}

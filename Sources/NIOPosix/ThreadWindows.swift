//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if !os(WASI)

#if os(Windows)

import WinSDK

/// Sendable wrapper around the Win32 `HANDLE` used by NIO threads.
///
/// `HANDLE` is `UnsafeMutableRawPointer?`, which is not `Sendable`. NIO's
/// `ThreadOps.ThreadHandle` is required to be `Sendable` (it lives inside
/// `NIOLockedValueBox` on `NIOThread`). The raw pointer is in fact safe to
/// share across threads — Win32 thread handles are designed for exactly
/// that. We therefore wrap it in an `@unchecked Sendable` struct.
struct NIOWindowsThreadHandle: @unchecked Sendable, Hashable {
    let raw: HANDLE

    init(_ raw: HANDLE) {
        self.raw = raw
    }

    static func == (lhs: NIOWindowsThreadHandle, rhs: NIOWindowsThreadHandle) -> Bool {
        lhs.raw == rhs.raw
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(UInt(bitPattern: raw))
    }
}

typealias ThreadOpsSystem = ThreadOpsWindows
enum ThreadOpsWindows: ThreadOps {
    typealias ThreadHandle = NIOWindowsThreadHandle
    typealias ThreadSpecificKey = DWORD
    typealias ThreadSpecificKeyDestructor = @convention(c) (UnsafeMutableRawPointer?) -> Void

    static func threadName(_ thread: ThreadOpsSystem.ThreadHandle) -> String? {
        var pszBuffer: PWSTR?
        GetThreadDescription(thread.raw, &pszBuffer)
        guard let buffer = pszBuffer else { return nil }
        let string: String = String(decodingCString: buffer, as: UTF16.self)
        LocalFree(buffer)
        return string
    }

    static func run(
        handle: inout ThreadOpsSystem.ThreadHandle?,
        args: Box<NIOThread.ThreadBoxValue>
    ) {
        let argv0 = Unmanaged.passRetained(args).toOpaque()

        // FIXME(compnerd) this should use the `stdcall` calling convention
        let routine: @convention(c) (UnsafeMutableRawPointer?) -> CUnsignedInt = {
            let boxed = Unmanaged<NIOThread.ThreadBox>.fromOpaque($0!).takeRetainedValue()
            let (body, name) = (boxed.value.body, boxed.value.name)
            let hThread: HANDLE = GetCurrentThread()

            if let name = name {
                _ = name.withCString(encodedAs: UTF16.self) {
                    SetThreadDescription(hThread, $0)
                }
            }

            body(NIOThread(handle: NIOWindowsThreadHandle(hThread), desiredName: name))

            return 0
        }
        let hThread: HANDLE =
            HANDLE(bitPattern: _beginthreadex(nil, 0, routine, argv0, 0, nil))!
        handle = NIOWindowsThreadHandle(hThread)
    }

    static func isCurrentThread(_ thread: ThreadOpsSystem.ThreadHandle) -> Bool {
        CompareObjectHandles(thread.raw, GetCurrentThread())
    }

    static var currentThread: ThreadOpsSystem.ThreadHandle {
        NIOWindowsThreadHandle(GetCurrentThread())
    }

    static func joinThread(_ thread: ThreadOpsSystem.ThreadHandle) {
        let dwResult: DWORD = WaitForSingleObject(thread.raw, INFINITE)
        assert(dwResult == WAIT_OBJECT_0, "WaitForSingleObject: \(GetLastError())")
    }

    static func allocateThreadSpecificValue(destructor: @escaping ThreadSpecificKeyDestructor) -> ThreadSpecificKey {
        FlsAlloc(destructor)
    }

    static func deallocateThreadSpecificValue(_ key: ThreadSpecificKey) {
        let dwResult: Bool = FlsFree(key)
        precondition(dwResult, "FlsFree: \(GetLastError())")
    }

    static func getThreadSpecificValue(_ key: ThreadSpecificKey) -> UnsafeMutableRawPointer? {
        FlsGetValue(key)
    }

    static func setThreadSpecificValue(key: ThreadSpecificKey, value: UnsafeMutableRawPointer?) {
        FlsSetValue(key, value)
    }

    static func compareThreads(_ lhs: ThreadOpsSystem.ThreadHandle, _ rhs: ThreadOpsSystem.ThreadHandle) -> Bool {
        CompareObjectHandles(lhs.raw, rhs.raw)
    }
}

#endif
#endif  // !os(WASI)

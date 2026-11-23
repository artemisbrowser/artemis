// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation

#if ARTEMIS_COVERAGE
    @_silgen_name("__llvm_profile_set_filename") private func llvmProfileSetFilename(_ name: UnsafePointer<CChar>)
    @_silgen_name("__llvm_profile_write_file") private func llvmProfileWriteFile() -> Int32
    @_silgen_name("__llvm_profile_reset_counters") private func llvmProfileResetCounters()
#endif

/// Coverage builds (`PERF_COVERAGE=1 tools/perflab.sh`) slice their counters by self-test group or bench loop.
enum Coverage {
    /// Writes the counters gathered since the last mark to `$ARTEMIS_COVERAGE_DIR/<slice>.profraw`, then zeroes them.
    /// True when it wrote a slice.
    @discardableResult static func mark(_ slice: String) -> Bool {
        #if ARTEMIS_COVERAGE
            guard let dir = ProcessInfo.processInfo.environment["ARTEMIS_COVERAGE_DIR"] else { return false }
            // the runtime keeps the pointer, not a copy
            llvmProfileSetFilename(strdup("\(dir)/\(slice).profraw"))
            _ = llvmProfileWriteFile()
            llvmProfileResetCounters()
            // the exit-time write lands here, outside every slice
            llvmProfileSetFilename(strdup("\(dir)/_rest.profraw"))
            return true
        #else
            return false
        #endif
    }
}

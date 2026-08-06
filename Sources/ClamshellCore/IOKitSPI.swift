import Foundation
import IOKit

// ⚠️ 이 파일은 프로젝트에서 **유일하게** 비공개 인터페이스(SPI)를 선언하는 곳이다.
// macOS 업데이트로 깨지면 여기만 보면 된다.
//
// 두 심볼 모두 공개 SDK 헤더(IOPMLib.h)에는 선언이 없다. IOPMLibPrivate.h 소속이다.
// 다만 MacOSX26.5.sdk 의 IOKit.tbd 에 `_IOPMSetSystemPowerSetting`,
// `_IOPMCopySystemPowerSettings` 로 export 되어 있어 링크는 정상이다.
// pmset 자신도 이 심볼을 쓴다.
//
// silgen 선언은 이 파일 밖으로 새어나가지 않는다 — 바깥에는 타입 있는
// `SystemPowerSettings` 만 보인다.

@_silgen_name("IOPMCopySystemPowerSettings")
private func _IOPMCopySystemPowerSettings() -> Unmanaged<CFDictionary>?

@_silgen_name("IOPMSetSystemPowerSetting")
private func _IOPMSetSystemPowerSetting(_ key: CFString, _ value: CFTypeRef) -> IOReturn

/// `SleepDisabled` 설정에 대한 좁은 창구.
///
/// **읽기는 root 없이 되고, 쓰기는 root 가 반드시 필요하다.**
/// `IOPMSetSystemPowerSetting` 진입부가 `(getuid()!=0 && geteuid()!=0)` 이면
/// 즉시 `kIOReturnNotPrivileged` 를 낸다.
///
/// 그리고 쓰기는 **비동기다.** 이 함수는 디스크(CFPreferences)에 희망값을 쓰고
/// powerd 를 깨울 뿐이며, 커널 반영은 powerd 가 나중에 한다.
/// 따라서 성공 반환을 신뢰하지 말고 `IOKitPowerStateReader` 로 실적용을
/// 폴링 확인해야 한다. DESIGN.md §1 참조.
public enum SystemPowerSettings {

    /// IOPMLibPrivate.h: `#define kIOPMSleepDisabledKey CFSTR("SleepDisabled")`
    public static let sleepDisabledKey = "SleepDisabled"

    /// 디스크에 저장된 **희망값**을 읽는다. root 불필요.
    ///
    /// 커널에 실제로 반영된 값과 다를 수 있다 — 그쪽은 `IOPMrootDomain` 프로퍼티로 읽는다.
    /// 키가 아예 없으면 nil.
    public static func readDesiredSleepDisabled() -> Bool? {
        guard let settings = _IOPMCopySystemPowerSettings()?.takeRetainedValue()
                as? [String: Any]
        else { return nil }
        return settings[sleepDisabledKey] as? Bool
    }

    /// 디스크에 저장된 시스템 전원 설정 전체. 진단용.
    public static func readAll() -> [String: Any] {
        (_IOPMCopySystemPowerSettings()?.takeRetainedValue() as? [String: Any]) ?? [:]
    }

    /// `SleepDisabled` 를 설정한다. **root 전용.**
    ///
    /// Phase 2 에서 헬퍼만 호출한다. 앱 본체에서 부르면 `kIOReturnNotPrivileged` 다.
    @discardableResult
    public static func writeSleepDisabled(_ value: Bool) -> IOReturn {
        _IOPMSetSystemPowerSetting(
            sleepDisabledKey as CFString,
            (value ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef
        )
    }
}

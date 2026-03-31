import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';
import 'package:flutter/material.dart';
import 'package:project_y/main.dart'; // 确保 DeviceData 定义在这里面

// 结构体映射
final class CustomHidAttributes extends Struct {
  @Uint32()
  external int Size;
  @Uint16()
  external int VendorID;
  @Uint16()
  external int ProductID;
  @Uint16()
  external int VersionNumber;
}

final DynamicLibrary _hidLib = DynamicLibrary.open('hid.dll');
final DynamicLibrary _kernelLib = DynamicLibrary.open('kernel32.dll');

typedef _HidD_GetHidGuid_C = Void Function(Pointer<GUID> guid);
typedef _HidD_GetHidGuid_Dart = void Function(Pointer<GUID> guid);
final _HidD_GetHidGuid =
    _hidLib.lookupFunction<_HidD_GetHidGuid_C, _HidD_GetHidGuid_Dart>(
  'HidD_GetHidGuid',
);

typedef _HidD_GetAttributes_C = Bool Function(
  IntPtr deviceHandle,
  Pointer<CustomHidAttributes> attributes,
);
typedef _HidD_GetAttributes_Dart = bool Function(
  int deviceHandle,
  Pointer<CustomHidAttributes> attributes,
);
final _HidD_GetAttributes =
    _hidLib.lookupFunction<_HidD_GetAttributes_C, _HidD_GetAttributes_Dart>(
  'HidD_GetAttributes',
);

typedef _WriteFile_C = Int32 Function(
  IntPtr hFile,
  Pointer<Uint8> lpBuffer,
  Uint32 nNumberOfBytesToWrite,
  Pointer<Uint32> lpNumberOfBytesWritten,
  Pointer<OVERLAPPED> lpOverlapped,
);
typedef _WriteFile_Dart = int Function(
  int hFile,
  Pointer<Uint8> lpBuffer,
  int nNumberOfBytesToWrite,
  Pointer<Uint32> lpNumberOfBytesWritten,
  Pointer<OVERLAPPED> lpOverlapped,
);
final _WriteFile =
    _kernelLib.lookupFunction<_WriteFile_C, _WriteFile_Dart>('WriteFile');

typedef _ReadFile_C = Int32 Function(
  IntPtr hFile,
  Pointer<Uint8> lpBuffer,
  Uint32 nNumberOfBytesToRead,
  Pointer<Uint32> lpNumberOfBytesRead,
  Pointer<OVERLAPPED> lpOverlapped,
);
typedef _ReadFile_Dart = int Function(
  int hFile,
  Pointer<Uint8> lpBuffer,
  int nNumberOfBytesToRead,
  Pointer<Uint32> lpNumberOfBytesRead,
  Pointer<OVERLAPPED> lpOverlapped,
);
final _ReadFile = _kernelLib.lookupFunction<_ReadFile_C, _ReadFile_Dart>(
  'ReadFile',
);

typedef _GetOverlappedResult_C = Int32 Function(
  IntPtr hFile,
  Pointer<OVERLAPPED> lpOverlapped,
  Pointer<Uint32> lpNumberOfBytesTransferred,
  Int32 bWait,
);
typedef _GetOverlappedResult_Dart = int Function(
  int hFile,
  Pointer<OVERLAPPED> lpOverlapped,
  Pointer<Uint32> lpNumberOfBytesTransferred,
  int bWait,
);
final _GetOverlappedResult = _kernelLib.lookupFunction<
    _GetOverlappedResult_C,
    _GetOverlappedResult_Dart>('GetOverlappedResult');

typedef _CancelIoEx_C = Int32 Function(
  IntPtr hFile,
  Pointer<OVERLAPPED> lpOverlapped,
);
typedef _CancelIoEx_Dart = int Function(
  int hFile,
  Pointer<OVERLAPPED> lpOverlapped,
);
final _CancelIoEx =
    _kernelLib.lookupFunction<_CancelIoEx_C, _CancelIoEx_Dart>('CancelIoEx');

class LogitechDriver {
  static const int logitechVid = 0x046D;
  static const int _hidppUnifiedBatteryFeatureHigh = 0x10;
  static const int _hidppUnifiedBatteryFeatureLow = 0x04;
  static const int _hidppUnifiedBatteryStatusFunction = 0x10;

  // 先尝试 0x11（Long），失败回退 0x10（USB 场景兼容）
  int _preferredReportId = 0x11;

  // 性能参数：显著缩短单次等待
  static const Duration _ioTimeout = Duration(milliseconds: 25);
  static const int _maxReadAttempts = 8;
  static const Duration _totalBudget = Duration(milliseconds: 1800);

  // 缓存：减少每次都根查询 feature
  int? _cachedFeatureIndex;
  DateTime? _cacheTime;
  static const Duration _cacheTtl = Duration(seconds: 30);

  bool _isExpired(DateTime deadline) => DateTime.now().isAfter(deadline);

  bool _writeFileWithTimeout(
    Arena arena,
    int hDevice,
    Pointer<Uint8> buf,
    int len,
    Duration timeout,
  ) {
    final overlapped = arena<OVERLAPPED>();
    final bytesWritten = arena<Uint32>();

    final hEvent = CreateEvent(nullptr, TRUE, FALSE, nullptr);
    if (hEvent == NULL) return false;
    overlapped.ref.hEvent = hEvent;

    final writeRet = _WriteFile(hDevice, buf, len, bytesWritten, overlapped);
    if (writeRet != 0) {
      CloseHandle(hEvent);
      return true;
    }

    final err = GetLastError();
    if (err != ERROR_IO_PENDING) {
      CloseHandle(hEvent);
      return false;
    }

    final waitRet = WaitForSingleObject(hEvent, timeout.inMilliseconds);
    if (waitRet == WAIT_OBJECT_0) {
      final ok =
          _GetOverlappedResult(hDevice, overlapped, bytesWritten, FALSE) != 0;
      CloseHandle(hEvent);
      return ok && bytesWritten.value > 0;
    }

    _CancelIoEx(hDevice, overlapped);
    CloseHandle(hEvent);
    return false;
  }

  bool _readFileWithTimeout(
    Arena arena,
    int hDevice,
    Pointer<Uint8> buf,
    int len,
    Duration timeout,
  ) {
    final overlapped = arena<OVERLAPPED>();
    final bytesRead = arena<Uint32>();

    final hEvent = CreateEvent(nullptr, TRUE, FALSE, nullptr);
    if (hEvent == NULL) return false;
    overlapped.ref.hEvent = hEvent;

    final readRet = _ReadFile(hDevice, buf, len, bytesRead, overlapped);
    if (readRet != 0) {
      CloseHandle(hEvent);
      return bytesRead.value > 0;
    }

    final err = GetLastError();
    if (err != ERROR_IO_PENDING) {
      CloseHandle(hEvent);
      return false;
    }

    final waitRet = WaitForSingleObject(hEvent, timeout.inMilliseconds);
    if (waitRet == WAIT_OBJECT_0) {
      final ok =
          _GetOverlappedResult(hDevice, overlapped, bytesRead, FALSE) != 0;
      CloseHandle(hEvent);
      return ok && bytesRead.value > 0;
    }

    _CancelIoEx(hDevice, overlapped);
    CloseHandle(hEvent);
    return false;
  }

  int _queryFeatureIndexWithReportId(
    Arena arena,
    int hDevice,
    int reportId,
    int featureIdHigh,
    int featureIdLow,
    DateTime deadline,
  ) {
    if (_isExpired(deadline)) return 0;

    final buf = arena<Uint8>(20);
    final list = buf.asTypedList(20);
    list.fillRange(0, 20, 0);

    list[0] = reportId;
    list[1] = 0x01;
    list[2] = 0x00;
    list[3] = 0x00;
    list[4] = featureIdHigh;
    list[5] = featureIdLow;

    final writeOk = _writeFileWithTimeout(arena, hDevice, buf, 20, _ioTimeout);
    if (!writeOk) return 0;

    for (int i = 0; i < _maxReadAttempts; i++) {
      if (_isExpired(deadline)) return 0;

      final readBuf = arena<Uint8>(20);
      final readOk =
          _readFileWithTimeout(arena, hDevice, readBuf, 20, _ioTimeout);
      if (!readOk) continue;

      final readList = readBuf.asTypedList(20);

      if (readList[0] == 0x01 || readList[0] == 0x02) continue;

      if (readList[1] == 0x01 && readList[2] == 0x00 && readList[3] == 0x00) {
        return readList[4];
      }
    }

    return 0;
  }

  int _getFeatureIndex(
    Arena arena,
    int hDevice,
    int featureIdHigh,
    int featureIdLow,
    DateTime deadline,
  ) {
    int idx = _queryFeatureIndexWithReportId(
      arena,
      hDevice,
      _preferredReportId,
      featureIdHigh,
      featureIdLow,
      deadline,
    );
    if (idx != 0) return idx;

    if (_isExpired(deadline)) return 0;

    final fallback = _preferredReportId == 0x11 ? 0x10 : 0x11;
    idx = _queryFeatureIndexWithReportId(
      arena,
      hDevice,
      fallback,
      featureIdHigh,
      featureIdLow,
      deadline,
    );
    if (idx != 0) _preferredReportId = fallback;
    return idx;
  }

  bool _readBatteryWithReportId(
    Arena arena,
    int hDevice,
    int reportId,
    int featureIndex,
    DateTime deadline,
    void Function(int battery, bool isCharging) onSuccess,
  ) {
    if (_isExpired(deadline)) return false;

    final buf = arena<Uint8>(20);
    final list = buf.asTypedList(20);
    list.fillRange(0, 20, 0);

    const int functionCode = _hidppUnifiedBatteryStatusFunction;

    list[0] = reportId;
    list[1] = 0x01;
    list[2] = featureIndex;
    list[3] = functionCode;

    final writeOk = _writeFileWithTimeout(arena, hDevice, buf, 20, _ioTimeout);
    if (!writeOk) return false;

    for (int i = 0; i < _maxReadAttempts; i++) {
      if (_isExpired(deadline)) return false;

      final readBuf = arena<Uint8>(20);
      final readOk =
          _readFileWithTimeout(arena, hDevice, readBuf, 20, _ioTimeout);
      if (!readOk) continue;

      final readList = readBuf.asTypedList(20);

      if (readList[0] == 0x01 || readList[0] == 0x02) continue;

      if (readList[1] == 0x01 &&
          readList[2] == featureIndex &&
          (readList[3] & 0xF0) == functionCode) {
        final int battery = readList[4].clamp(0, 100);
        final int status = readList[6];
        final bool isCharging =
            (status == 1 || status == 2 || status == 3 || status == 4);

        onSuccess(battery, isCharging);
        return true;
      }
    }

    return false;
  }

  DeviceData getBatteryStatus() {
    return using((Arena arena) {
      final deadline = DateTime.now().add(_totalBudget);

      final guid = arena<GUID>();
      _HidD_GetHidGuid(guid);

      final hDevInfo = SetupDiGetClassDevs(
        guid,
        nullptr,
        0,
        DIGCF_PRESENT | DIGCF_DEVICEINTERFACE,
      );
      if (hDevInfo == INVALID_HANDLE_VALUE) {
        return DeviceData(name: '罗技 GPW 2代', icon: Icons.mouse, isConnected: false);
      }

      final deviceInterfaceData = arena<SP_DEVICE_INTERFACE_DATA>();
      deviceInterfaceData.ref.cbSize = sizeOf<SP_DEVICE_INTERFACE_DATA>();

      int index = 0;
      while (SetupDiEnumDeviceInterfaces(
            hDevInfo,
            nullptr,
            guid,
            index++,
            deviceInterfaceData,
          ) !=
          0) {
        if (_isExpired(deadline)) break;

        final detailSize = arena<Uint32>();
        SetupDiGetDeviceInterfaceDetail(
          hDevInfo,
          deviceInterfaceData,
          nullptr,
          0,
          detailSize,
          nullptr,
        );

        if (detailSize.value <= 0) continue;

        final rawBuffer = arena<Uint8>(detailSize.value);
        rawBuffer.cast<Uint32>().value = (sizeOf<IntPtr>() == 8) ? 8 : 5;

        if (SetupDiGetDeviceInterfaceDetail(
              hDevInfo,
              deviceInterfaceData,
              rawBuffer.cast(),
              detailSize.value,
              nullptr,
              nullptr,
            ) ==
            0) {
          continue;
        }

        final pathPtr = rawBuffer.elementAt(4).cast<Utf16>();

        final hDevice = CreateFile(
          pathPtr,
          GENERIC_READ | GENERIC_WRITE,
          FILE_SHARE_READ | FILE_SHARE_WRITE,
          nullptr,
          OPEN_EXISTING,
          FILE_FLAG_OVERLAPPED,
          0,
        );
        if (hDevice == INVALID_HANDLE_VALUE) continue;

        final attributes = arena<CustomHidAttributes>();
        attributes.ref.Size = sizeOf<CustomHidAttributes>();

        if (!(_HidD_GetAttributes(hDevice, attributes) &&
            attributes.ref.VendorID == logitechVid)) {
          CloseHandle(hDevice);
          continue;
        }

        DeviceData? result;

        final bool hasFreshCache = _cachedFeatureIndex != null &&
            _cacheTime != null &&
            DateTime.now().difference(_cacheTime!) < _cacheTtl;

        if (hasFreshCache && !_isExpired(deadline)) {
          bool ok = _readBatteryWithReportId(
            arena,
            hDevice,
            _preferredReportId,
            _cachedFeatureIndex!,
            deadline,
            (int battery, bool isCharging) {
              result = DeviceData(
                name: '罗技 GPW 2代',
                icon: Icons.mouse,
                batteryLevel: battery,
                isCharging: isCharging,
                isConnected: true,
              );
            },
          );

          if (!ok && !_isExpired(deadline)) {
            final fallback = _preferredReportId == 0x11 ? 0x10 : 0x11;
            ok = _readBatteryWithReportId(
              arena,
              hDevice,
              fallback,
              _cachedFeatureIndex!,
              deadline,
              (int battery, bool isCharging) {
                result = DeviceData(
                  name: '罗技 GPW 2代',
                  icon: Icons.mouse,
                  batteryLevel: battery,
                  isCharging: isCharging,
                  isConnected: true,
                );
              },
            );
            if (ok) _preferredReportId = fallback;
          }

          if (ok && result != null) {
            CloseHandle(hDevice);
            SetupDiDestroyDeviceInfoList(hDevInfo);
            return result!;
          }
        }

        final int featureIndex =
            _getFeatureIndex(
              arena,
              hDevice,
              _hidppUnifiedBatteryFeatureHigh,
              _hidppUnifiedBatteryFeatureLow,
              deadline,
            );
        if (featureIndex != 0 && !_isExpired(deadline)) {
          _cachedFeatureIndex = featureIndex;
          _cacheTime = DateTime.now();

          bool ok = _readBatteryWithReportId(
            arena,
            hDevice,
            _preferredReportId,
            featureIndex,
            deadline,
            (int battery, bool isCharging) {
              result = DeviceData(
                name: '罗技 GPW 2代',
                icon: Icons.mouse,
                batteryLevel: battery,
                isCharging: isCharging,
                isConnected: true,
              );
            },
          );

          if (!ok && !_isExpired(deadline)) {
            final fallback = _preferredReportId == 0x11 ? 0x10 : 0x11;
            ok = _readBatteryWithReportId(
              arena,
              hDevice,
              fallback,
              featureIndex,
              deadline,
              (int battery, bool isCharging) {
                result = DeviceData(
                  name: '罗技 GPW 2代',
                  icon: Icons.mouse,
                  batteryLevel: battery,
                  isCharging: isCharging,
                  isConnected: true,
                );
              },
            );
            if (ok) _preferredReportId = fallback;
          }

          CloseHandle(hDevice);
          if (ok && result != null) {
            SetupDiDestroyDeviceInfoList(hDevInfo);
            return result!;
          }
        }

        CloseHandle(hDevice);
      }

      SetupDiDestroyDeviceInfoList(hDevInfo);
      return DeviceData(name: '罗技 GPW 2代', icon: Icons.mouse, isConnected: false);
    });
  }
}

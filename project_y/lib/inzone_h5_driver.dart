import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

// ===================== HID 基础定义 =====================

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

final class HIDP_CAPS extends Struct {
  @Uint16()
  external int UsagePage;
  @Uint16()
  external int Usage;
  @Uint16()
  external int InputReportByteLength;
  @Uint16()
  external int OutputReportByteLength;
  @Uint16()
  external int FeatureReportByteLength;
  @Array(17)
  external Array<Uint16> Reserved;
  @Uint16()
  external int NumberLinkCollectionNodes;
  @Uint16()
  external int NumberInputButtonCaps;
  @Uint16()
  external int NumberInputValueCaps;
  @Uint16()
  external int NumberInputDataIndices;
  @Uint16()
  external int NumberOutputButtonCaps;
  @Uint16()
  external int NumberOutputValueCaps;
  @Uint16()
  external int NumberOutputDataIndices;
  @Uint16()
  external int NumberFeatureButtonCaps;
  @Uint16()
  external int NumberFeatureValueCaps;
  @Uint16()
  external int NumberFeatureDataIndices;
}

final DynamicLibrary _hidLib = DynamicLibrary.open('hid.dll');

// HidD_GetHidGuid
typedef _HidD_GetHidGuid_C = Void Function(Pointer<GUID> guid);
typedef _HidD_GetHidGuid_Dart = void Function(Pointer<GUID> guid);
final _HidD_GetHidGuid =
    _hidLib.lookupFunction<_HidD_GetHidGuid_C, _HidD_GetHidGuid_Dart>('HidD_GetHidGuid');
void HidD_GetHidGuid(Pointer<GUID> guid) => _HidD_GetHidGuid(guid);

// HidD_GetAttributes
typedef _HidD_GetAttributes_C = Bool Function(IntPtr deviceHandle, Pointer<CustomHidAttributes> attributes);
typedef _HidD_GetAttributes_Dart = bool Function(int deviceHandle, Pointer<CustomHidAttributes> attributes);
final _HidD_GetAttributes =
    _hidLib.lookupFunction<_HidD_GetAttributes_C, _HidD_GetAttributes_Dart>('HidD_GetAttributes');
bool HidD_GetAttributes(int deviceHandle, Pointer<CustomHidAttributes> attributes) =>
    _HidD_GetAttributes(deviceHandle, attributes);

// HidD_GetPreparsedData / HidD_FreePreparsedData / HidP_GetCaps
typedef _HidD_GetPreparsedData_C = Bool Function(IntPtr deviceHandle, Pointer<Pointer<Void>> preparsedData);
typedef _HidD_GetPreparsedData_Dart = bool Function(int deviceHandle, Pointer<Pointer<Void>> preparsedData);
final _HidD_GetPreparsedData =
    _hidLib.lookupFunction<_HidD_GetPreparsedData_C, _HidD_GetPreparsedData_Dart>('HidD_GetPreparsedData');

typedef _HidD_FreePreparsedData_C = Bool Function(Pointer<Void> preparsedData);
typedef _HidD_FreePreparsedData_Dart = bool Function(Pointer<Void> preparsedData);
final _HidD_FreePreparsedData =
    _hidLib.lookupFunction<_HidD_FreePreparsedData_C, _HidD_FreePreparsedData_Dart>('HidD_FreePreparsedData');

typedef _HidP_GetCaps_C = Int32 Function(Pointer<Void> preparsedData, Pointer<Void> caps);
typedef _HidP_GetCaps_Dart = int Function(Pointer<Void> preparsedData, Pointer<Void> caps);
final _HidP_GetCaps = _hidLib.lookupFunction<_HidP_GetCaps_C, _HidP_GetCaps_Dart>('HidP_GetCaps');

// ===================== HID 常量 =====================

const int HIDP_STATUS_SUCCESS = 0x00110000;

// ===================== 数据结构 =====================

class InzoneH5Data {
  final int batteryLevel; // 0-100
  final bool isCharging;
  final bool isConnected;

  InzoneH5Data({
    this.batteryLevel = 0,
    this.isCharging = false,
    this.isConnected = false,
  });
}

class _InzoneHandles {
  final int? ctrlHandle; // 发送 SET_REPORT 的句柄（类似 2.1.0）
  final int? inHandle; // 接收 INTERRUPT IN 的句柄（类似 2.1.3）
  _InzoneHandles({this.ctrlHandle, this.inHandle});
}

// ===================== 驱动实现 =====================

class InzoneH5Driver {
  static const sonyVid = 0x054C;
  static const inzoneH5Pid = 0x0EBF;

  // 你抓包确认：SET_REPORT 的 Data Fragment 为 64 字节
  // 模板A（你后来图里出现 0x41 0x04 ... 0xa0）
  static const List<int> _requestA = [
    0x02, 0x0c, 0x01, 0x00, 0xfc, 0x08, 0x96, 0xc3,
    0x41, 0x04, 0x01, 0x01, 0x00, 0xa0, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  ];

  // 是否开启日志
  static const bool _verboseLog = true;

  InzoneH5Data getBatteryStatus() {
    return using((arena) {
      _log('=== getBatteryStatus begin ===');

      final handles = _openInzoneHandles(arena);
      _log('handles ctrl=${_h(handles.ctrlHandle)} in=${_h(handles.inHandle)}');

      if (handles.ctrlHandle == null && handles.inHandle == null) {
        _log('No valid handle found');
        return InzoneH5Data(isConnected: false);
      }

      final ctrl = handles.ctrlHandle;
      final input = handles.inHandle ?? handles.ctrlHandle!;

      _log('Try request template A');

      if (ctrl != null) {
        final writeOk = _writeRequest(ctrl, _requestA);
        _log('write template A: $writeOk');
      } else {
        _log('ctrl handle is null, skip write');
      }

      final result = _readBatteryWithTimeout(input, timeoutMs: 500);
      if (result != null) {
        _closeHandles(handles);
        _log('Battery success: ${result.batteryLevel}%, charging=${result.isCharging}');
        return result;
      }

      _closeHandles(handles);
      _log('Template A no battery packet');
      _log('Connected but no battery packet captured');
      return InzoneH5Data(isConnected: false, isCharging: false, batteryLevel: 0);
    });
  }

  // ===================== 核心：枚举并选句柄 =====================

  _InzoneHandles _openInzoneHandles(Arena arena) {
    final guid = arena<GUID>();
    HidD_GetHidGuid(guid);

    final hDevInfo = SetupDiGetClassDevs(guid, nullptr, 0, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    if (hDevInfo == INVALID_HANDLE_VALUE) {
      _log('SetupDiGetClassDevs failed, err=${GetLastError()}');
      return _InzoneHandles();
    }

    final deviceInterfaceData = arena<SP_DEVICE_INTERFACE_DATA>();
    deviceInterfaceData.ref.cbSize = sizeOf<SP_DEVICE_INTERFACE_DATA>();

    int? ctrlHandle;
    int? inHandle;
    int index = 0;

    while (SetupDiEnumDeviceInterfaces(hDevInfo, nullptr, guid, index++, deviceInterfaceData) != 0) {
      final detailSize = arena<Uint32>();
      SetupDiGetDeviceInterfaceDetail(hDevInfo, deviceInterfaceData, nullptr, 0, detailSize, nullptr);
      if (detailSize.value == 0) continue;

      final rawBuffer = arena<Uint8>(detailSize.value);
      rawBuffer.cast<Uint32>().value = (sizeOf<IntPtr>() == 8) ? 8 : 5;

      if (SetupDiGetDeviceInterfaceDetail(
            hDevInfo,
            deviceInterfaceData,
            rawBuffer.cast(),
            detailSize.value,
            nullptr,
            nullptr,
          ) == 0) {
        _log('SetupDiGetDeviceInterfaceDetail failed, err=${GetLastError()}');
        continue;
      }

      final pathPtr = rawBuffer.elementAt(4).cast<Utf16>();
      final path = pathPtr.toDartString();
      _log('Interface path: $path');

      final hDevice = CreateFile(
        pathPtr,
        GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        nullptr,
        OPEN_EXISTING,
        FILE_FLAG_OVERLAPPED,
        0,
      );

      if (hDevice == INVALID_HANDLE_VALUE) {
        _log('CreateFile failed, err=${GetLastError()}');
        continue;
      }

      final attributes = arena<CustomHidAttributes>()..ref.Size = sizeOf<CustomHidAttributes>();
      if (!HidD_GetAttributes(hDevice, attributes.cast())) {
        _log('HidD_GetAttributes failed, err=${GetLastError()}');
        CloseHandle(hDevice);
        continue;
      }

      if (attributes.ref.VendorID != sonyVid || attributes.ref.ProductID != inzoneH5Pid) {
        CloseHandle(hDevice);
        continue;
      }

      final preparsed = arena<Pointer<Void>>();
      if (!_HidD_GetPreparsedData(hDevice, preparsed)) {
        _log('HidD_GetPreparsedData failed, err=${GetLastError()}');
        CloseHandle(hDevice);
        continue;
      }

      final caps = arena<HIDP_CAPS>();
      final nt = _HidP_GetCaps(preparsed.value, caps.cast<Void>());
      _HidD_FreePreparsedData(preparsed.value);

      if (nt != HIDP_STATUS_SUCCESS) {
        _log('HidP_GetCaps failed, nt=$nt');
        CloseHandle(hDevice);
        continue;
      }

      _log(
        'caps: inLen=${caps.ref.InputReportByteLength}, outLen=${caps.ref.OutputReportByteLength}, '
        'featureLen=${caps.ref.FeatureReportByteLength}, usagePage=0x${caps.ref.UsagePage.toRadixString(16)}, '
        'usage=0x${caps.ref.Usage.toRadixString(16)}',
      );

      if (ctrlHandle == null && caps.ref.OutputReportByteLength >= 64) {
        ctrlHandle = hDevice;
        _log('select ctrlHandle=${_h(ctrlHandle)}');
        if (inHandle != null) break;
        continue;
      }

      if (inHandle == null && caps.ref.InputReportByteLength >= 64) {
        inHandle = hDevice;
        _log('select inHandle=${_h(inHandle)}');
        if (ctrlHandle != null) break;
        continue;
      }

      CloseHandle(hDevice);
    }

    SetupDiDestroyDeviceInfoList(hDevInfo);
    return _InzoneHandles(ctrlHandle: ctrlHandle, inHandle: inHandle);
  }

  // ===================== 核心：写请求 =====================

  bool _writeRequest(int handle, List<int> request64) {
    return using((arena) {
      if (!_isUsableHandle(handle)) {
        _log('write skip: invalid handle ${_h(handle)}');
        return false;
      }

      final writeBuf = arena<Uint8>(64);
      for (int i = 0; i < 64; i++) {
        writeBuf[i] = request64[i];
      }

      final ov = arena<OVERLAPPED>();
      ov.ref.hEvent = CreateEvent(nullptr, TRUE, FALSE, nullptr);
      if (ov.ref.hEvent == NULL || ov.ref.hEvent == INVALID_HANDLE_VALUE) {
        _log('CreateEvent(write) failed err=${GetLastError()}');
        return false;
      }

      final bytesWritten = arena<Uint32>()..value = 0;
      try {
        final r = WriteFile(handle, writeBuf, 64, nullptr, ov);
        if (r == 0) {
          final err = GetLastError();
          if (err == ERROR_IO_PENDING) {
            final wait = WaitForSingleObject(ov.ref.hEvent, 150);
            if (wait != WAIT_OBJECT_0) {
              _log('Write timeout/abnormal wait=$wait err=${GetLastError()}');
              CancelIo(handle); // best-effort
              return false;
            }
            if (GetOverlappedResult(handle, ov, bytesWritten, FALSE) == 0) {
              final e = GetLastError();
              _log('GetOverlappedResult(write) failed err=$e');
              return false;
            }
          } else if (_isDeviceGoneError(err)) {
            _log('WriteFile device unavailable err=$err');
            return false;
          } else {
            _log('WriteFile failed err=$err');
            return false;
          }
        } else {
          if (GetOverlappedResult(handle, ov, bytesWritten, FALSE) == 0) {
            final e = GetLastError();
            if (!_isDeviceGoneError(e)) {
              _log('GetOverlappedResult(write sync) failed err=$e');
            }
          }
        }

        _log('TX(${bytesWritten.value}): ${_hex(Uint8List.fromList(request64))}');
        return true;
      } finally {
        CloseHandle(ov.ref.hEvent);
      }
    });
  }

  // ===================== 核心：读电量包（不阻塞） =====================

  InzoneH5Data? _readBatteryWithTimeout(int inputHandle, {int timeoutMs = 1800}) {
    return using((arena) {
      if (!_isUsableHandle(inputHandle)) {
        _log('read skip: invalid handle ${_h(inputHandle)}');
        return null;
      }

      final readBuf = arena<Uint8>(64);
      final bytesRead = arena<Uint32>();

      final ov = arena<OVERLAPPED>();
      ov.ref.hEvent = CreateEvent(nullptr, TRUE, FALSE, nullptr);
      if (ov.ref.hEvent == NULL || ov.ref.hEvent == INVALID_HANDLE_VALUE) {
        _log('CreateEvent(read) failed err=${GetLastError()}');
        return null;
      }

      final started = GetTickCount();
      int loops = 0;

      try {
        while (GetTickCount() - started < timeoutMs) {
          loops++;
          bytesRead.value = 0;
          ResetEvent(ov.ref.hEvent);

          final r = ReadFile(inputHandle, readBuf, 64, nullptr, ov);
          if (r == 0) {
            final err = GetLastError();

            if (err == ERROR_IO_PENDING) {
              final wait = WaitForSingleObject(ov.ref.hEvent, 80);
              if (wait == WAIT_OBJECT_0) {
                final ok = GetOverlappedResult(inputHandle, ov, bytesRead, FALSE);
                if (ok == 0) {
                  final e = GetLastError();
                  if (_isDeviceGoneError(e)) {
                    _log('read device unavailable err=$e');
                    return null;
                  }
                  _log('GetOverlappedResult(read) failed err=$e');
                  continue;
                }
              } else if (wait == WAIT_TIMEOUT) {
                CancelIo(inputHandle); // best-effort
                continue;
              } else {
                _log('WaitForSingleObject(read) abnormal=$wait err=${GetLastError()}');
                break;
              }
            } else if (_isDeviceGoneError(err)) {
              _log('ReadFile device unavailable err=$err');
              return null;
            } else {
              _log('ReadFile immediate fail err=$err');
              break;
            }
          } else {
            if (GetOverlappedResult(inputHandle, ov, bytesRead, FALSE) == 0) {
              final e = GetLastError();
              if (_isDeviceGoneError(e)) {
                _log('read sync device unavailable err=$e');
                return null;
              }
              _log('GetOverlappedResult(read sync) failed err=$e');
              continue;
            }
          }

          if (bytesRead.value == 0) {
            continue;
          }

          final data = readBuf.asTypedList(bytesRead.value);
          _log('RX(${bytesRead.value}) loop=$loops: ${_hex(data)}');

          // 你确认的电量报文：02 0e 04
          if (data.length >= 15 && data[0] == 0x02 && data[1] == 0x0e && data[2] == 0x04) {
            final isCharging = data[13] == 0x01; // offset12
            final battery = data[14].clamp(0, 100); // offset13
            _log('Battery packet matched -> charging=$isCharging, battery=$battery');
            return InzoneH5Data(
              batteryLevel: battery,
              isCharging: isCharging,
              isConnected: true,
            );
          }
        }
      } finally {
        CloseHandle(ov.ref.hEvent);
      }

      _log('No battery packet captured in ${timeoutMs}ms');
      return null;
    });
  }

  // ===================== 资源释放 =====================

  void _closeHandles(_InzoneHandles handles) {
    if (_isUsableHandle(handles.ctrlHandle)) {
      CloseHandle(handles.ctrlHandle!);
    }
    if (_isUsableHandle(handles.inHandle) && handles.inHandle != handles.ctrlHandle) {
      CloseHandle(handles.inHandle!);
    }
  }

  // ===================== 错误与日志工具 =====================

  static bool _isUsableHandle(int? h) {
    return h != null && h != NULL && h != INVALID_HANDLE_VALUE;
  }

  // 耳机关机/链路断开时常见错误码（Windows HID/USB）
  static bool _isDeviceGoneError(int err) {
    return err == ERROR_DEVICE_NOT_CONNECTED || // 1167
        err == ERROR_GEN_FAILURE || // 31
        err == ERROR_OPERATION_ABORTED || // 995
        err == ERROR_INVALID_HANDLE || // 6
        err == ERROR_NOT_READY || // 21
        err == ERROR_NO_SUCH_DEVICE; // 433
  }

  static String _h(int? h) => h == null ? 'null' : '0x${h.toRadixString(16)}';

  static String _hex(Uint8List data, {int max = 64}) {
    final n = data.length < max ? data.length : max;
    final b = StringBuffer();
    for (int i = 0; i < n; i++) {
      b.write(data[i].toRadixString(16).padLeft(2, '0'));
      if (i != n - 1) b.write(' ');
    }
    return b.toString();
  }

  static void _log(String msg) {
    if (_verboseLog) {
      print('[INZONE_H5] $msg');
    }
  }
}
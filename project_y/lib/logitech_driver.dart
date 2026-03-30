import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';
import 'package:flutter/material.dart'; // 修复 Undefined name 'Icons'
import 'package:project_y/main.dart'; // 引入 DeviceData 模型

// 修复 HIDD_ATTRIBUTES 报错：沿用你原有的自定义结构体
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
final _HidD_GetHidGuid = _hidLib.lookupFunction<_HidD_GetHidGuid_C, _HidD_GetHidGuid_Dart>('HidD_GetHidGuid');

// 使用 CustomHidAttributes 替换原先的报错定义
typedef _HidD_GetAttributes_C = Bool Function(IntPtr deviceHandle, Pointer<CustomHidAttributes> attributes);
typedef _HidD_GetAttributes_Dart = bool Function(int deviceHandle, Pointer<CustomHidAttributes> attributes);
final _HidD_GetAttributes = _hidLib.lookupFunction<_HidD_GetAttributes_C, _HidD_GetAttributes_Dart>('HidD_GetAttributes');

typedef _WriteFile_C = Int32 Function(IntPtr hFile, Pointer<Uint8> lpBuffer, Uint32 nNumberOfBytesToWrite, Pointer<Uint32> lpNumberOfBytesWritten, Pointer<Void> lpOverlapped);
typedef _WriteFile_Dart = int Function(int hFile, Pointer<Uint8> lpBuffer, int nNumberOfBytesToWrite, Pointer<Uint32> lpNumberOfBytesWritten, Pointer<Void> lpOverlapped);
final _WriteFile = _kernelLib.lookupFunction<_WriteFile_C, _WriteFile_Dart>('WriteFile');

class LogitechDriver {
  static const int logitechVid = 0x046D;

  DeviceData getBatteryStatus() {
    return using((Arena arena) {
      final guid = arena<GUID>();
      _HidD_GetHidGuid(guid);

      final hDevInfo = SetupDiGetClassDevs(guid, nullptr, 0, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
      if (hDevInfo == INVALID_HANDLE_VALUE) return DeviceData(name: '', icon: Icons.mouse);

      final deviceInterfaceData = arena<SP_DEVICE_INTERFACE_DATA>();
      deviceInterfaceData.ref.cbSize = sizeOf<SP_DEVICE_INTERFACE_DATA>();

      int index = 0;
      while (SetupDiEnumDeviceInterfaces(hDevInfo, nullptr, guid, index++, deviceInterfaceData) != 0) {
        final detailSize = arena<Uint32>();
        SetupDiGetDeviceInterfaceDetail(hDevInfo, deviceInterfaceData, nullptr, 0, detailSize, nullptr);

        if (detailSize.value > 0) {
          final rawBuffer = arena<Uint8>(detailSize.value);
          rawBuffer.cast<Uint32>().value = (sizeOf<IntPtr>() == 8) ? 8 : 5;

          if (SetupDiGetDeviceInterfaceDetail(hDevInfo, deviceInterfaceData, rawBuffer.cast(), detailSize.value, nullptr, nullptr) != 0) {
            final pathPtr = rawBuffer.elementAt(4).cast<Utf16>();
            final hDevice = CreateFile(pathPtr, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING, 0, 0);

            if (hDevice != INVALID_HANDLE_VALUE) {
              final attributes = arena<CustomHidAttributes>();
              attributes.ref.Size = sizeOf<CustomHidAttributes>();

              if (_HidD_GetAttributes(hDevice, attributes) && attributes.ref.VendorID == logitechVid) {
                
                // --- 罗技 HID++ 2.0 协议查询 ---
                final buffer = arena<Uint8>(20);
                final bytesWritten = arena<Uint32>();
                final bytesRead = arena<Uint32>();
                
                buffer[0] = 0x11; // HID++ Long Message
                buffer[1] = 0x01; // Device Index (无线设备通常挂在 0x01)
                buffer[2] = 0x08; // Feature Index (0x08 是罗技常见的 Battery 获取 Feature ID)
                buffer[3] = 0x00; // Function ID 0 (Get Level)
                
                if (_WriteFile(hDevice, buffer, 20, bytesWritten, nullptr) != 0) {
                  final readBuffer = arena<Uint8>(20);
                  
                  // 马上读取返回的数据包
                  if (ReadFile(hDevice, readBuffer, 20, bytesRead, nullptr) != 0) {
                     final data = readBuffer.asTypedList(20);
                     
                     // 验证是否是我们的回复报文 (ReportID=0x11, DeviceIndex=0x01)
                     if (data[0] == 0x11 && data[1] == 0x01) {
                        int battery = data[4]; // 字节 4 是百分比
                        int status = data[5];  // 字节 5 是充电状态
                        
                        CloseHandle(hDevice);
                        SetupDiDestroyDeviceInfoList(hDevInfo);
                        return DeviceData(
                          name: '罗技 GPW 2代',
                          icon: Icons.mouse,
                          batteryLevel: battery.clamp(0, 100),
                          isCharging: status == 1 || status == 2,
                          isConnected: true,
                        );
                     }
                  }
                }
              }
              CloseHandle(hDevice);
            }
          }
        }
      }
      SetupDiDestroyDeviceInfoList(hDevInfo);
      return DeviceData(name: '罗技 GPW 2代', icon: Icons.mouse, isConnected: false);
    });
  }
}
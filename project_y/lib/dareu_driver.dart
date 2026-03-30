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

typedef _HidD_GetHidGuid_C = Void Function(Pointer<GUID> guid);
typedef _HidD_GetHidGuid_Dart = void Function(Pointer<GUID> guid);
final _HidD_GetHidGuid = _hidLib.lookupFunction<_HidD_GetHidGuid_C, _HidD_GetHidGuid_Dart>('HidD_GetHidGuid');

// 使用 CustomHidAttributes 替换原先的报错定义
typedef _HidD_GetAttributes_C = Bool Function(IntPtr deviceHandle, Pointer<CustomHidAttributes> attributes);
typedef _HidD_GetAttributes_Dart = bool Function(int deviceHandle, Pointer<CustomHidAttributes> attributes);
final _HidD_GetAttributes = _hidLib.lookupFunction<_HidD_GetAttributes_C, _HidD_GetAttributes_Dart>('HidD_GetAttributes');

typedef _HidD_SetFeature_C = Bool Function(IntPtr hidDeviceObject, Pointer<Void> reportBuffer, Uint32 reportBufferLength);
typedef _HidD_SetFeature_Dart = bool Function(int hidDeviceObject, Pointer<Void> reportBuffer, int reportBufferLength);
final _HidD_SetFeature = _hidLib.lookupFunction<_HidD_SetFeature_C, _HidD_SetFeature_Dart>('HidD_SetFeature');

typedef _HidD_GetFeature_C = Bool Function(IntPtr hidDeviceObject, Pointer<Void> reportBuffer, Uint32 reportBufferLength);
typedef _HidD_GetFeature_Dart = bool Function(int hidDeviceObject, Pointer<Void> reportBuffer, int reportBufferLength);
final _HidD_GetFeature = _hidLib.lookupFunction<_HidD_GetFeature_C, _HidD_GetFeature_Dart>('HidD_GetFeature');

class DareuDriver {
  static const int dareuVid = 0x258A;
  static const int dareuPid = 0x0060;

  DeviceData getBatteryStatus() {
    return using((Arena arena) {
      final guid = arena<GUID>();
      _HidD_GetHidGuid(guid);

      final hDevInfo = SetupDiGetClassDevs(guid, nullptr, 0, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
      if (hDevInfo == INVALID_HANDLE_VALUE) return DeviceData(name: '', icon: Icons.keyboard);

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

              if (_HidD_GetAttributes(hDevice, attributes) && attributes.ref.VendorID == dareuVid && attributes.ref.ProductID == dareuPid) {
                
                // --- 达尔优 (合盈方案) 私有协议抓包还原 ---
                final featureBuffer = arena<Uint8>(65);
                
                // 构建查询请求包 
                featureBuffer[0] = 0x00; // Report ID 
                featureBuffer[1] = 0x00; // TargetId
                featureBuffer[2] = 0x04; // Size
                featureBuffer[3] = 0x07; // CLASS_POWER
                featureBuffer[4] = 0x80; // CMD_BAT_STATUS | GET_CMD
                
                // 发送 Feature Report
                if (_HidD_SetFeature(hDevice, featureBuffer.cast(), 65)) {
                  // 读取返回的 Feature Report
                  if (_HidD_GetFeature(hDevice, featureBuffer.cast(), 65)) {
                    final data = featureBuffer.asTypedList(65);
                    
                    int status = data[7]; // 状态
                    int battery = data[8]; // 电量百分比
                    
                    CloseHandle(hDevice);
                    SetupDiDestroyDeviceInfoList(hDevInfo);
                    
                    return DeviceData(
                      name: '达尔优 EK87 PRO',
                      icon: Icons.keyboard,
                      batteryLevel: battery.clamp(0, 100),
                      isCharging: status == 0x01 || status == 0x02,
                      isConnected: true,
                    );
                  }
                }
              }
              CloseHandle(hDevice);
            }
          }
        }
      }
      SetupDiDestroyDeviceInfoList(hDevInfo);
      return DeviceData(name: '达尔优 EK87 PRO', icon: Icons.keyboard, isConnected: false);
    });
  }
}
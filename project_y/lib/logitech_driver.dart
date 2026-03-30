import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
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
final _HidD_GetHidGuid = _hidLib.lookupFunction<_HidD_GetHidGuid_C, _HidD_GetHidGuid_Dart>('HidD_GetHidGuid');

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
                
                // --- 核心方法：向根节点查询动态频道的真实索引 ---
                int getFeatureIndex(int featureIdHigh, int featureIdLow) {
                  final buf = arena<Uint8>(20);
                  final list = buf.asTypedList(20);
                  list.fillRange(0, 20, 0);
                  
                  list[0] = 0x11; // Long Message
                  list[1] = 0x01; // Device Index
                  list[2] = 0x00; // Root Feature
                  list[3] = 0x00; // Function 0: GetFeature
                  list[4] = featureIdHigh;
                  list[5] = featureIdLow;
                  
                  final bytesWritten = arena<Uint32>();
                  if (_WriteFile(hDevice, buf, 20, bytesWritten, nullptr) != 0) {
                    // 读取多次，防止恰好读取到鼠标移动坐标的数据包 (坐标包是 0x01 / 0x02 开头)
                    for (int i = 0; i < 20; i++) {
                      final readBuf = arena<Uint8>(20);
                      final bytesRead = arena<Uint32>();
                      if (ReadFile(hDevice, readBuf, 20, bytesRead, nullptr) != 0) {
                        final readList = readBuf.asTypedList(20);
                        if (readList[0] == 0x11 && readList[1] == 0x01 && readList[2] == 0x00 && readList[3] == 0x00) {
                          return readList[4]; // 成功拿到频道索引
                        }
                      }
                    }
                  }
                  return 0;
                }

                // ==============================================
                // 第一步：获取电池管理频道的准确位址
                // ==============================================
                int featureIndex = 0;
                bool isUnifiedBattery = true;

                // 优先查询 GPW2 的 0x1004 频道
                featureIndex = getFeatureIndex(0x10, 0x04);
                if (featureIndex == 0) {
                  // 回退查询老款使用的 0x1000 频道
                  featureIndex = getFeatureIndex(0x10, 0x00);
                  isUnifiedBattery = false;
                }

                // ==============================================
                // 第二步：索要真实电量（修复了 Function ID 的大坑）
                // ==============================================
                if (featureIndex != 0) {
                  final buf = arena<Uint8>(20);
                  final list = buf.asTypedList(20);
                  list.fillRange(0, 20, 0);

                  // 决定查询状态的函数ID：
                  // 0x1004 的查状态是 Function 1 (位运算: 0x10)
                  // 0x1000 的查状态是 Function 0 (位运算: 0x00)
                  int functionId = isUnifiedBattery ? 1 : 0;

                  list[0] = 0x11; 
                  list[1] = 0x01; 
                  list[2] = featureIndex; 
                  list[3] = functionId << 4; // 发送查电量的核心！
                  
                  final bytesWritten = arena<Uint32>();
                  if (_WriteFile(hDevice, buf, 20, bytesWritten, nullptr) != 0) {
                    for (int i = 0; i < 20; i++) {
                      final readBuf = arena<Uint8>(20);
                      final bytesRead = arena<Uint32>();
                      if (ReadFile(hDevice, readBuf, 20, bytesRead, nullptr) != 0) {
                        final readList = readBuf.asTypedList(20);
                        
                        // 确认回复是我们刚才调用的 Function
                        if (readList[0] == 0x11 && 
                            readList[1] == 0x01 && 
                            readList[2] == featureIndex && 
                            (readList[3] & 0xF0) == (functionId << 4)) {
                          
                          int battery = readList[4]; // 真·电量
                          int status = readList[6];  // 对于 0x1000 和 0x1004，状态都在索引 6
                          
                          bool isCharging = (status == 1 || status == 2 || status == 3 || status == 4);

                          CloseHandle(hDevice);
                          SetupDiDestroyDeviceInfoList(hDevInfo);
                          return DeviceData(
                            name: '罗技 GPW 2代',
                            icon: Icons.mouse,
                            batteryLevel: battery.clamp(0, 100),
                            isCharging: isCharging,
                            isConnected: true,
                          );
                        }
                      }
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
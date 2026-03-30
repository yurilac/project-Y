import 'dart:ffi';
import 'dart:io';
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

// 定义达尔优设备配置（同时支持 2.4G 和 有线模式）
class DareuConfig {
  final int vid;
  final int pid;
  final int targetId; // 核心：无线接收器需要 0x10 来路由到键盘

  const DareuConfig(this.vid, this.pid, this.targetId);
}

class DareuDriver {
  static const List<DareuConfig> supportedDevices = [
    DareuConfig(0x260D, 0x0037, 0x10), // 2.4G 接收器 (将命令路由给通道1的设备)
    DareuConfig(0x258A, 0x0060, 0x00), // 有线直连模式
  ];

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

            // Windows 机制：系统级键盘接口会返回 Access Denied，代码会自动继续循环，
            // 直到碰到厂商自定义接口(Vendor Defined)才会拿到有效的可读写 hDevice
            final hDevice = CreateFile(pathPtr, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING, 0, 0);

            if (hDevice != INVALID_HANDLE_VALUE) {
              final attributes = arena<CustomHidAttributes>();
              attributes.ref.Size = sizeOf<CustomHidAttributes>();

              if (_HidD_GetAttributes(hDevice, attributes)) {
                
                // 【核心修改 1】：匹配设备是否在已知列表内
                DareuConfig? currentConfig;
                for (var cfg in supportedDevices) {
                  if (attributes.ref.VendorID == cfg.vid && attributes.ref.ProductID == cfg.pid) {
                    currentConfig = cfg;
                    break;
                  }
                }

                if (currentConfig != null) {
                  final featureBuffer = arena<Uint8>(65);
                  final dataList = featureBuffer.asTypedList(65);
                  
                  dataList.fillRange(0, 65, 0);
                  
                  // 【核心修改 2】：依照 TgHidDevice 构建私有协议数据包
                  dataList[0] = 0x00; // Report ID 
                  dataList[1] = currentConfig.targetId; // TargetId (发送给接收器必须要填 0x10)
                  dataList[2] = 0x03; // HDR_SIZE (固定尺寸 0x03)
                  dataList[3] = 0x07; // HDR_CLASS (CLASS_POWER)
                  dataList[4] = 0x80; // HDR_COMMAND (PWR_CMD_BAT_STATUS | GET_CMD)
                  dataList[5] = 0x00; // HDR_PROFILE
                  
                  // 下发查询指令
                  if (_HidD_SetFeature(hDevice, featureBuffer.cast(), 65)) {
                    
                    // 无线模式由于需要接收器跟键盘空中通讯，一定要加入延时轮询
                    for (int retry = 0; retry < 20; retry++) {
                      sleep(const Duration(milliseconds: 15)); // 等待空中包返回
                      
                      dataList.fillRange(0, 65, 0);
                      dataList[0] = 0x00;
                      
                      if (_HidD_GetFeature(hDevice, featureBuffer.cast(), 65)) {
                        
                        // 校验是否属于有效应答 (低 4 位等于 0x02)
                        int hdrStatus = dataList[1];
                        if ((hdrStatus & 0x0F) == 0x02) {
                          
                          // 取出电量：索引偏移自 JS 中的 PAYLOAD_BASE (即 0x06) + 1
                          // 在包含 Report ID[0] 的 Dart 数组里，就是 7 和 8 
                          int status = dataList[7];
                          int battery = dataList[8];
                          
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
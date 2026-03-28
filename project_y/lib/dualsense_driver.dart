import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';



// 修复错误 (4)：手动定义 HID 属性结构体。
// 命名为 CustomHidAttributes 以防与某些 win32 库版本冲突
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
final DynamicLibrary _setupLib = DynamicLibrary.open('setupapi.dll');
final DynamicLibrary _kernelLib = DynamicLibrary.open('kernel32.dll');

// HidD_GetHidGuid
typedef _HidD_GetHidGuid_C = Void Function(Pointer<GUID> guid);
typedef _HidD_GetHidGuid_Dart = void Function(Pointer<GUID> guid);
final _HidD_GetHidGuid = _hidLib.lookupFunction<_HidD_GetHidGuid_C, _HidD_GetHidGuid_Dart>('HidD_GetHidGuid');
void HidD_GetHidGuid(Pointer<GUID> guid) => _HidD_GetHidGuid(guid);

// HidD_GetAttributes
typedef _HidD_GetAttributes_C = Bool Function(IntPtr deviceHandle, Pointer<CustomHidAttributes> attributes);
typedef _HidD_GetAttributes_Dart = bool Function(int deviceHandle, Pointer<CustomHidAttributes> attributes);
final _HidD_GetAttributes = _hidLib.lookupFunction<_HidD_GetAttributes_C, _HidD_GetAttributes_Dart>('HidD_GetAttributes');
bool HidD_GetAttributes(int deviceHandle, Pointer<CustomHidAttributes> attributes) => _HidD_GetAttributes(deviceHandle, attributes);



class DualSenseData {
  final int batteryLevel; // 0-100
  final bool isCharging;
  final bool isConnected;

  DualSenseData({
    this.batteryLevel = 0,
    this.isCharging = false,
    this.isConnected = false,
  });
}

class DualSenseDriver {
  static const sonyVid = 0x054C;
  static const dualSensePid = 0x0CE6;

  

  DualSenseData getBatteryStatus() {
    void HidD_GetHidGuid(Pointer<GUID> guid) => _HidD_GetHidGuid(guid);
    return using((Arena arena) {
      final guid = arena<GUID>();
      HidD_GetHidGuid(guid);

      final hDevInfo = SetupDiGetClassDevs(guid, nullptr, 0, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
      if (hDevInfo == INVALID_HANDLE_VALUE) return DualSenseData(isConnected: false);

      final deviceInterfaceData = arena<SP_DEVICE_INTERFACE_DATA>();
      deviceInterfaceData.ref.cbSize = sizeOf<SP_DEVICE_INTERFACE_DATA>();

      int index = 0;
      while (SetupDiEnumDeviceInterfaces(hDevInfo, nullptr, guid, index++, deviceInterfaceData) != 0) {
        final detailSize = arena<Uint32>();
        
        // 第一步：获取需要的内存大小
        SetupDiGetDeviceInterfaceDetail(hDevInfo, deviceInterfaceData, nullptr, 0, detailSize, nullptr);

        if (detailSize.value > 0) {
          // 第二步：直接分配原始内存，不使用具体的结构体类型
          final rawBuffer = arena<Uint8>(detailSize.value);
          
          // 关键点：手动模拟结构体头部的 cbSize 赋值
          // 在 64 位 Windows 上，这个结构体的 cbSize 映射通常是 8 (4字节size + 4字节对齐) 
          // 或者在 32 位上是 5/6。win32 插件通常期望这里设为 8
          final cbSizeValue = (sizeOf<IntPtr>() == 8) ? 8 : 5;
          rawBuffer.cast<Uint32>().value = cbSizeValue;

          // 第三步：填充内存
          if (SetupDiGetDeviceInterfaceDetail(hDevInfo, deviceInterfaceData, rawBuffer.cast(), detailSize.value, nullptr, nullptr) != 0) {
            
            // 第四步：从偏移位置提取设备路径字符串
            // 路径紧跟在 cbSize 字段之后（4字节偏移）
            final pathPtr = rawBuffer.elementAt(4).cast<Utf16>();

            final hDevice = CreateFile(
              pathPtr,
              GENERIC_READ | GENERIC_WRITE,
              FILE_SHARE_READ | FILE_SHARE_WRITE,
              nullptr,
              OPEN_EXISTING,
              0,
              0,
            );

            if (hDevice != INVALID_HANDLE_VALUE) {
              final attributes = arena<CustomHidAttributes>();
              attributes.ref.Size = sizeOf<CustomHidAttributes>();

              if (HidD_GetAttributes(hDevice, attributes.cast()) != 0) {
                if (attributes.ref.VendorID == sonyVid && attributes.ref.ProductID == dualSensePid) {
                  final buffer = arena<Uint8>(78);
                  final bytesRead = arena<Uint32>();
                  buffer[0] = 0x31; 

                  if (ReadFile(hDevice, buffer, 78, bytesRead, nullptr) != 0) {
                    final data = buffer.asTypedList(78);
                    int rawBattery = data[54] & 0x0F;
                    int status = (data[54] & 0xF0) >> 4;

                    CloseHandle(hDevice);
                    SetupDiDestroyDeviceInfoList(hDevInfo);
                    return DualSenseData(
                      batteryLevel: (rawBattery * 10).clamp(0, 100),
                      isCharging: status == 0x1,
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
      return DualSenseData(isConnected: false);
    });
  }
  
}


/// fsync a directory so a rename inside it survives a crash. dart:io has no
/// API for this, so it calls libc (Linux/Android) through dart:ffi. Best
/// effort: returns false, never throws, where libc or the call fails.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

typedef _OpenC = Int32 Function(Pointer<Uint8>, Int32);
typedef _Open = int Function(Pointer<Uint8>, int);
typedef _FdC = Int32 Function(Int32);
typedef _Fd = int Function(int);
typedef _MallocC = Pointer<Uint8> Function(IntPtr);
typedef _Malloc = Pointer<Uint8> Function(int);
typedef _FreeC = Void Function(Pointer<Uint8>);
typedef _Free = void Function(Pointer<Uint8>);

const int _oRdonly = 0;

bool fsyncDirectory(String path) {
  if (!(Platform.isLinux || Platform.isAndroid)) return false;
  try {
    final libc = Platform.isAndroid
        ? DynamicLibrary.open('libc.so')
        : DynamicLibrary.process();
    final open = libc.lookupFunction<_OpenC, _Open>('open');
    final fsync = libc.lookupFunction<_FdC, _Fd>('fsync');
    final close = libc.lookupFunction<_FdC, _Fd>('close');
    final malloc = libc.lookupFunction<_MallocC, _Malloc>('malloc');
    final free = libc.lookupFunction<_FreeC, _Free>('free');
    final units = utf8.encode(path);
    final buf = malloc(units.length + 1);
    if (buf.address == 0) return false;
    try {
      buf.asTypedList(units.length + 1)
        ..setAll(0, units)
        ..[units.length] = 0;
      final fd = open(buf, _oRdonly);
      if (fd < 0) return false;
      try {
        return fsync(fd) == 0;
      } finally {
        close(fd);
      }
    } finally {
      free(buf);
    }
  } on Object {
    return false;
  }
}

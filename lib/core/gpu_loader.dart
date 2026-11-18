import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Makes the CUDA pack in [dir] resolvable before the sherpa-onnx GPU library
/// is opened. Runs inside the recognizer isolate.
///
/// * Windows: adds [dir] to the DLL search path (CUDA/cuDNN DLLs are loaded
///   lazily by onnxruntime_providers_cuda.dll) and preloads the GPU build of
///   onnxruntime.dll so the CPU copy next to the exe is not picked up.
/// * Linux: preloads the CUDA libraries by full path so their sonames are
///   already satisfied when onnxruntime's CUDA provider is dlopen()ed.
void preloadGpuRuntime(String dir) {
  if (Platform.isWindows) {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final setDllDirectory = kernel32
        .lookupFunction<Int32 Function(Pointer<Utf16>), int Function(Pointer<Utf16>)>('SetDllDirectoryW');
    final path = dir.toNativeUtf16();
    try {
      setDllDirectory(path);
    } finally {
      malloc.free(path);
    }
    DynamicLibrary.open('$dir\\onnxruntime.dll');
    return;
  }
  if (Platform.isLinux) {
    final files = Directory(dir).listSync().whereType<File>().map((f) => f.path).toList();
    // Dependency order: runtime, BLAS, FFT, cuDNN (core before sub-libraries).
    const order = ['libcudart', 'libcublasLt', 'libcublas.', 'libcufft', 'libcudnn.so', 'libcudnn_'];
    for (final prefix in order) {
      for (final f in files.where((f) => f.split('/').last.startsWith(prefix))) {
        DynamicLibrary.open(f);
      }
    }
    final ort = files.where((f) => f.split('/').last.startsWith('libonnxruntime.so'));
    if (ort.isNotEmpty) DynamicLibrary.open(ort.first);
  }
}

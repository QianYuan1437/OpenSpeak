import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openspeak/core/gpu.dart';

void main() {
  test('extracts only the wanted libraries, flat, while UI listeners are attached', () async {
    final tmp = await Directory.systemTemp.createTemp('os_gpu_extract');
    addTearDown(() => tmp.delete(recursive: true));
    final archive = Archive()
      ..add(ArchiveFile.bytes('nvidia/cuda_runtime/bin/cudart64_12.dll', Uint8List(4096)))
      ..add(ArchiveFile.bytes('nvidia/cuda_runtime/include/cuda.h', Uint8List(16)))
      ..add(ArchiveFile.bytes('nvidia/cuda_runtime/bin/other.dll', Uint8List(16)));
    final zip = File('${tmp.path}/w.whl')..writeAsBytesSync(ZipEncoder().encode(archive));
    final out = await Directory('${tmp.path}/out').create();

    // The app's GpuManager has UI listeners that cannot cross isolates; the
    // extraction must not capture it.
    final port = ReceivePort();
    addTearDown(port.close);
    GpuManager().addListener(() => port.hashCode);

    await GpuManager.extractLibraries(zip.path, out.path,
        dir: 'nvidia/cuda_runtime/bin/', pattern: r'cudart64_12\.dll$');
    final names = out.listSync().map((e) => e.uri.pathSegments.last).toList();
    expect(names, ['cudart64_12.dll']);
    expect(File('${out.path}/cudart64_12.dll').lengthSync(), 4096);
  });
}

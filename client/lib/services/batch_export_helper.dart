import 'dart:io';

import 'package:file_picker/file_picker.dart';

import '../models/transcribe_task.dart';

/// 批量与单文件结果导出辅助类
class BatchExportHelper {
  /// 批量导出：让用户选择目标目录，将所有已完成任务分别保存为 `<原文件名>.txt`
  ///
  /// 返回导出的文件数量及目标目录路径；若用户取消选择返回 null。
  static Future<({int count, String directory})?> exportCompletedToDirectory(
    List<TranscribeTask> tasks,
  ) async {
    final completed = tasks
        .where((t) => t.status == TaskStatus.completed && t.resultText.isNotEmpty)
        .toList();
    if (completed.isEmpty) return null;

    final selectedDir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择导出文件夹',
    );
    if (selectedDir == null || selectedDir.isEmpty) return null;

    var exportedCount = 0;
    final usedNames = <String>{};

    for (final task in completed) {
      final baseName = _stripExtension(task.fileName);
      var safeName = '$baseName.txt';
      var counter = 1;

      // 防止重名覆盖
      while (usedNames.contains(safeName.toLowerCase()) ||
          File('$selectedDir/$safeName').existsSync()) {
        safeName = '${baseName}_$counter.txt';
        counter++;
      }
      usedNames.add(safeName.toLowerCase());

      final targetFile = File('$selectedDir/$safeName');
      await targetFile.writeAsString(task.resultText);
      exportedCount++;
    }

    return (count: exportedCount, directory: selectedDir);
  }

  /// 合并导出：将所有已完成的任务合并为一个总汇总 `.txt` 文件
  static Future<File?> exportMergedToSingleFile(
    List<TranscribeTask> tasks, {
    String? defaultFileName,
  }) async {
    final completed = tasks
        .where((t) => t.status == TaskStatus.completed && t.resultText.isNotEmpty)
        .toList();
    if (completed.isEmpty) return null;

    final name = defaultFileName ??
        'ASR_批量转写汇总_${DateTime.now().toString().split('.').first.replaceAll(':', '-')}.txt';

    final savePath = await FilePicker.platform.saveFile(
      dialogTitle: '保存汇总转写结果',
      fileName: name,
      type: FileType.custom,
      allowedExtensions: ['txt'],
    );
    if (savePath == null) return null;

    final buffer = StringBuffer();
    for (var i = 0; i < completed.length; i++) {
      final task = completed[i];
      buffer.writeln('========================================');
      buffer.writeln('【文件 ${i + 1}/${completed.length}】: ${task.fileName}');
      buffer.writeln('----------------------------------------');
      buffer.writeln(task.resultText);
      buffer.writeln();
    }

    final file = File(savePath);
    await file.writeAsString(buffer.toString());
    return file;
  }

  /// 单文件导出为 .txt
  static Future<File?> exportSingleTask(TranscribeTask task) async {
    if (task.resultText.isEmpty) return null;

    final baseName = _stripExtension(task.fileName);
    final savePath = await FilePicker.platform.saveFile(
      dialogTitle: '保存转写结果',
      fileName: '$baseName.txt',
      type: FileType.custom,
      allowedExtensions: ['txt'],
    );
    if (savePath == null) return null;

    final file = File(savePath);
    await file.writeAsString(task.resultText);
    return file;
  }

  static String _stripExtension(String fileName) {
    final dot = fileName.lastIndexOf('.');
    return dot == -1 ? fileName : fileName.substring(0, dot);
  }
}

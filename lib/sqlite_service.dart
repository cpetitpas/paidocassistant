import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'dart:convert';
import 'logging_service.dart';

class SQLiteService {
  late Database _db;

  SQLiteService();

  Future<void> init() async {
    loggingService.log("Initializing SQLite database...");
    final path = join(await getDatabasesPath(), 'pai.db');
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS chunks(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            file TEXT,
            content TEXT,
            embedding TEXT
          )
        ''');
      },
    );
    loggingService.log("SQLite database initialized at $path");
  }

  Future<void> insertChunk(String file, String content, List<double> embedding) async {
    loggingService.log("Inserting chunk for file: $file");
    final embeddingStr = jsonEncode(embedding);
    await _db.insert('chunks', {
      'file': file,
      'content': content,
      'embedding': embeddingStr,
    });
    loggingService.log("Chunk inserted.");
  }

  Future<List<Map<String, dynamic>>> getAllChunksWithEmbeddings() async {
    loggingService.log("Retrieving all chunks with embeddings...");
    final result = await _db.query('chunks');
    final mapped = result.map((row) {
      final embStr = row['embedding'] as String?;
      final embedding = embStr != null 
          ? (jsonDecode(embStr) as List).map((e) => e as double).toList() 
          : <double>[];
      return {
        "text": row['content'] as String,
        "embedding": embedding,
      };
    }).toList();
    loggingService.log("Retrieved ${result.length} chunks.");
    return mapped;
  }

  Future<void> clear() async {
    loggingService.log("Clearing database...");
    await _db.delete('chunks');
  }
}
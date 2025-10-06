import 'dart:math';
import 'sqlite_service.dart';
import 'tflite_service.dart';
import 'logging_service.dart';

class AskService {
  final TFLiteService tflite;
  final SQLiteService dbService;

  AskService({required this.tflite, required this.dbService});

  Future<String> ask({
    required String query,
    int maxChunks = 3,
    bool limitContext = true,
  }) async {
    loggingService.log("Received query: $query (limitContext=$limitContext)");
    try {
      final queryEmbedding = await tflite.createEmbedding(query);

      final allChunks = await dbService.getAllChunksWithEmbeddings();

      if (allChunks.isEmpty) {
        return "No documents found. Please upload some PDFs first.";
      }

      List<Map<String, dynamic>> scoredChunks = allChunks.map((chunk) {
        final chunkVector = chunk["embedding"] as List<double>;
        final score = cosineSimilarity(queryEmbedding, chunkVector);
        return {"text": chunk["text"], "score": score};
      }).toList();

      List<Map<String, dynamic>> selectedChunks;
      if (limitContext) {
        scoredChunks.sort((a, b) => b["score"].compareTo(a["score"]));
        selectedChunks = scoredChunks.take(maxChunks).toList();
        loggingService.log("Top $maxChunks chunks selected for context.");
      } else {
        selectedChunks = scoredChunks;
        loggingService.log("All chunks used for context (no limit).");
      }

      final combinedContext = selectedChunks.map((c) => c["text"] as String).join(" ");

      if (combinedContext.trim().isEmpty) {
        loggingService.log("No relevant chunks found.");
        return "No relevant information found in your documents.";
      }

      loggingService.log("Answering with MobileBERT QA");
      final answer = await tflite.answerQuestion(query, combinedContext);

      return answer.trim();
    } catch (e) {
      return "Error: ${e.toString()}";
    }
  }

  double cosineSimilarity(List<double> a, List<double> b) {
    assert(a.length == b.length);
    double dot = 0.0;
    double magA = 0.0;
    double magB = 0.0;
    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      magA += a[i] * a[i];
      magB += b[i] * b[i];
    }
    return dot / (sqrt(magA) * sqrt(magB) + 1e-8);
  }
}
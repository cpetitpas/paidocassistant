import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'logging_service.dart';

class TFLiteService {
  Interpreter? _embeddingInterpreter;
  Interpreter? _qaInterpreter;
  BertTokenizer? _tokenizer;
  bool _isInitialized = false;

  bool get isInitialized => _isInitialized;

  Future<void> init() async {
    try {
      loggingService.log("Initializing TFLite models...");
      
      // Load embedding model
      loggingService.log("Loading embedding_model.tflite...");
      _embeddingInterpreter = await Interpreter.fromAsset('assets/models/embedding_model.tflite');
      loggingService.log("Embedding model loaded successfully.");
      
      // Load QA model
      loggingService.log("Loading mobilebert.tflite...");
      _qaInterpreter = await Interpreter.fromAsset('assets/models/mobilebert.tflite');
      loggingService.log("QA model loaded successfully.");
      
      // Load tokenizer
      _tokenizer = BertTokenizer();
      loggingService.log("Loading vocab.txt...");
      await _tokenizer!.loadVocab();
      loggingService.log("Tokenizer initialized.");
      
      _isInitialized = true;
      loggingService.log("TFLiteService fully initialized.");
    } catch (e, stack) {
      _isInitialized = false;
      loggingService.error("Error initializing TFLite: $e\nStack: $stack");
      throw Exception("Failed to initialize TFLite models: $e");
    }
  }

  Future<List<double>> createEmbedding(String text, {int maxLength = 512}) async {
    if (!_isInitialized || _embeddingInterpreter == null) {
      loggingService.error("Embedding model not loaded or not initialized.");
      throw Exception("Embedding model not loaded.");
    }
    
    try {
      final tokens = _tokenizer!.tokenize(text);
      final inputIds = tokens.take(maxLength).toList().padRight(maxLength, 0);
      final input = [inputIds];
      // Adjust output shape based on your model (e.g., 384 or 768)
      final output = List.filled(1 * 768, 0.0).reshape([1, 768]);

      loggingService.log("Running embedding inference...");
      _embeddingInterpreter!.run(input, output);
      loggingService.log("Embedding inference completed.");
      
      return List<double>.from(output[0]);
    } catch (e, stack) {
      loggingService.error("Error creating embedding: $e\nStack: $stack");
      throw Exception("Embedding failed: $e");
    }
  }

  Future<String> answerQuestion(String question, String context, {int maxLength = 384}) async {
    if (!_isInitialized || _qaInterpreter == null) {
      loggingService.error("QA model not loaded or not initialized.");
      throw Exception("QA model not loaded.");
    }
    
    try {
      final qTokens = _tokenizer!.tokenize(question);
      final cTokens = _tokenizer!.tokenize(context);
      
      var tokens = [_tokenizer!._vocab['[CLS]'] ?? 101] + qTokens + [_tokenizer!._vocab['[SEP]'] ?? 102] + cTokens + [_tokenizer!._vocab['[SEP]'] ?? 102];
      if (tokens.length > maxLength) {
        tokens = tokens.sublist(0, maxLength);
      }
      
      final inputIds = tokens.padRight(maxLength, 0);
      final attentionMask = inputIds.map((id) => id != 0 ? 1 : 0).toList();
      final tokenTypeIds = List<int>.filled(maxLength, 0);
      for (int i = qTokens.length + 2; i < tokens.length; i++) {
        tokenTypeIds[i] = 1;
      }
      
      final inputs = [[inputIds], [attentionMask], [tokenTypeIds]];
      final startLogits = List.filled(1 * maxLength, 0.0).reshape([1, maxLength]);
      final endLogits = List.filled(1 * maxLength, 0.0).reshape([1, maxLength]);
      
      loggingService.log("Running QA inference...");
      _qaInterpreter!.runForMultipleInputs(inputs, {0: startLogits, 1: endLogits});
      loggingService.log("QA inference completed.");
      
      final startIdx = _argMax(startLogits[0] as List<double>);
      final endIdx = _argMax(endLogits[0] as List<double>);
      
      if (startIdx > endIdx || startIdx == 0 || endIdx == 0) {
        return "No clear answer found in the context.";
      }
      
      final answerTokens = tokens.sublist(startIdx, endIdx + 1);
      return _tokenizer!.detokenize(answerTokens);
    } catch (e, stack) {
      loggingService.error("Error answering question: $e\nStack: $stack");
      throw Exception("QA failed: $e");
    }
  }

  int _argMax(List<double> list) {
    double maxVal = list[0];
    int maxIdx = 0;
    for (int i = 1; i < list.length; i++) {
      if (list[i] > maxVal) {
        maxVal = list[i];
        maxIdx = i;
      }
    }
    return maxIdx;
  }

  void dispose() {
    _embeddingInterpreter?.close();
    _qaInterpreter?.close();
    _isInitialized = false;
    loggingService.log("TFLiteService disposed.");
  }
}

// BertTokenizer remains unchanged
class BertTokenizer {
  Map<String, int> _vocab = {};
  Map<int, String> _idToToken = {};

  Future<void> loadVocab() async {
    try {
      final vocabStr = await rootBundle.loadString('assets/models/vocab.txt');
      final lines = vocabStr.split('\n');
      for (int i = 0; i < lines.length; i++) {
        final token = lines[i].trim();
        if (token.isNotEmpty) {
          _vocab[token] = i;
          _idToToken[i] = token;
        }
      }
      loggingService.log("Vocabulary loaded with ${_vocab.length} tokens.");
    } catch (e, stack) {
      loggingService.error("Error loading vocab.txt: $e\nStack: $stack");
      throw Exception("Failed to load vocab.txt: $e");
    }
  }

  List<int> tokenize(String text) {
    text = text.toLowerCase();
    final words = _basicTokenize(text);
    final tokens = <int>[];
    
    for (var word in words) {
      if (_vocab.containsKey(word)) {
        tokens.add(_vocab[word]!);
      } else {
        final subTokens = _wordPieceTokenize(word);
        tokens.addAll(subTokens);
      }
    }
    return tokens;
  }

  List<String> _basicTokenize(String text) {
    final reg = RegExp(r"([.,!?;])");
    text = text.replaceAllMapped(reg, (m) => ' ${m.group(1)} ');
    return text.split(' ').where((w) => w.isNotEmpty).toList();
  }

  List<int> _wordPieceTokenize(String word, {int maxLength = 200}) {
    if (word.length > maxLength) {
      return [_vocab['[UNK]'] ?? 100];
    }
    
    final tokens = <int>[];
    String current = word;
    while (current.isNotEmpty) {
      String match = '';
      for (int len = current.length; len > 0; len--) {
        final prefix = current.substring(0, len);
        final candidate = tokens.isEmpty ? prefix : '##' + prefix;
        if (_vocab.containsKey(candidate)) {
          match = candidate;
          break;
        }
      }
      if (match.isNotEmpty) {
        tokens.add(_vocab[match]!);
        current = current.substring(match.startsWith('##') ? match.length - 2 : match.length);
      } else {
        tokens.add(_vocab['[UNK]'] ?? 100);
        break;
      }
    }
    return tokens;
  }

  String detokenize(List<int> tokenIds) {
    final tokens = tokenIds.map((id) => _idToToken[id] ?? '[UNK]').toList();
    String text = tokens.join(' ').replaceAll(' ##', '');
    return text;
  }
}

extension ListPadding<T> on List<T> {
  List<T> padRight(int length, T padValue) {
    final padded = List<T>.from(this);
    while (padded.length < length) {
      padded.add(padValue);
    }
    return padded;
  }
}
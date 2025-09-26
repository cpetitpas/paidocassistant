import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io';
import 'sqlite_service.dart';
import 'pdf_service.dart';
import 'openai_service.dart';
import 'logging_service.dart';
import 'ask_service.dart';
import 'purchase_service.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart' as perm;
import 'package:share_plus/share_plus.dart';
import 'dart:async';

void main() {
  runApp(const PAIApp());
}

class PAIApp extends StatelessWidget {
  const PAIApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "PAI Workflow",
      theme: ThemeData(
        primarySwatch: Colors.blue,
        textTheme: GoogleFonts.interTextTheme(),
      ),
      home: const WorkflowScreen(),
    );
  }
}

class WorkflowScreen extends StatefulWidget {
  const WorkflowScreen({super.key});

  @override
  State<WorkflowScreen> createState() => _WorkflowScreenState();
}

class UpgradePage extends StatelessWidget {
  final int trialDaysRemaining;
  final void Function(String productId) onPurchase;
  final bool isLifetimePurchased;
  final VoidCallback onRestorePurchases;
  final VoidCallback onSetTrialDate;

  const UpgradePage({
    super.key,
    required this.trialDaysRemaining,
    required this.onPurchase,
    required this.isLifetimePurchased,
    required this.onRestorePurchases,
    required this.onSetTrialDate,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Upgrade"),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isLifetimePurchased
                    ? "You have lifetime access! No further purchase is needed."
                    : trialDaysRemaining > 0
                        ? "Your free trial has $trialDaysRemaining day${trialDaysRemaining > 1 ? 's' : ''} remaining.\n\nUpgrade now to unlock full access:"
                        : "Your free trial has ended.\n\nUpgrade to continue using the app:",
                style: const TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 20),
              if (!isLifetimePurchased) ...[
                ElevatedButton(
                  onPressed: () => onPurchase("monthly"),
                  child: Text(useTestIds ? "Test: \$1.99 / month" : "\$1.99 / month"),
                ),
                ElevatedButton(
                  onPressed: () => onPurchase("yearly"),
                  child: Text(useTestIds ? "Test: \$19.99 / year" : "\$19.99 / year"),
                ),
              ],
              ElevatedButton(
                onPressed: isLifetimePurchased ? null : () => onPurchase("lifetime"),
                child: Text(useTestIds ? "Test: \$49 Lifetime" : "\$49 Lifetime"),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: onRestorePurchases,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.grey.shade300,
                  foregroundColor: Colors.black,
                ),
                child: const Text("Restore Purchases"),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: onSetTrialDate,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange,
                  foregroundColor: Colors.black,
                ),
                child: const Text("Set Trial Date (Test Only)"),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Toggle flag: true = test mode, false = production
const bool useTestIds = false;

// Real product IDs from Google Play Console
const String subscriptionId = "pai_subscription";
const String lifetimePlanId = "pai_lifetime";

// Test product IDs provided by Google
const String testPurchasedId = "android.test.purchased";
const String testCanceledId = "android.test.canceled";
const String testRefundedId = "android.test.refunded";
const String testUnavailableId = "android.test.item_unavailable";

// Function to get the current product ID
String getProductId(String productKey) {
  if (useTestIds) {
    switch (productKey) {
      case "monthly":
      case "yearly":
      case "lifetime":
        return testPurchasedId;
      default:
        return testUnavailableId;
    }
  } else {
    switch (productKey) {
      case "monthly":
      case "yearly":
        return subscriptionId;
      case "lifetime":
        return lifetimePlanId;
      default:
        return "";
    }
  }
}

class _WorkflowScreenState extends State<WorkflowScreen> {
  bool limitContext = true;
  int? currentStep = 0;
  int trialDaysRemaining = 0;
  Timer? _trialTimer;
  String apiKey = "";
  final ScrollController chatScrollController = ScrollController();
  final TextEditingController queryController = TextEditingController();
  final List<Map<String, String>> chatHistory = [];
  final InAppPurchase _iap = InAppPurchase.instance;
  final Map<String, List<ProductDetails>> _productDetails = {};
  bool isLifetimePurchased = false;

  List<String> pdfPaths = [];
  List<String> previousQuestions = [];
  bool termsExpanded = false;
  bool showLimitContextInfo = false;
  bool showPreviousQuestions = false;

  late OpenAIService openAIService;
  late SQLiteService dbService;
  late PdfService pdfService;
  late AskService askService;
  late StreamSubscription<List<PurchaseDetails>> _subscription;
  final FlutterSecureStorage storage = const FlutterSecureStorage();
  final PurchaseService purchaseService = PurchaseService();

  @override
  void initState() {
    super.initState();
    openAIService = OpenAIService();
    dbService = SQLiteService(openAI: openAIService);
    pdfService = PdfService(dbService, openAIService);
    dbService.init();
    askService = AskService(openAI: openAIService, dbService: dbService);
    _checkAccess();
    _subscription = _iap.purchaseStream.listen(
      (purchases) async {
        bool hasLifetime = false;
        for (var purchase in purchases) {
          if (purchase.status == PurchaseStatus.purchased ||
              purchase.status == PurchaseStatus.restored) {
            await _handlePurchase(purchase);
            if (purchase.productID == lifetimePlanId) {
              hasLifetime = true;
            }
          } else if (purchase.status == PurchaseStatus.error) {
            loggingService.error("Purchase error: ${purchase.error?.message}");
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text("Purchase Error: ${purchase.error?.message}")),
            );
          }
        }
        if (!hasLifetime && purchases.isNotEmpty) {
          loggingService.log("No lifetime purchase found in restored purchases. Clearing lifetime status.");
          await purchaseService.setLifetime(false);
          setState(() {
            isLifetimePurchased = false;
          });
        }
      },
      onDone: () {
        loggingService.log("Purchase stream closed.");
        _subscription.cancel();
      },
      onError: (error) {
        loggingService.error("Purchase stream error: $error");
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Purchase Stream Error: $error")),
        );
      },
    );
    _loadProducts();
    _loadApiKey();
    _checkLifetimeStatus();
    Future.delayed(Duration.zero, checkPastPurchases);
  }

  Future<void> _checkLifetimeStatus() async {
    final hasLifetime = await purchaseService.hasLifetime();
    setState(() {
      isLifetimePurchased = hasLifetime;
    });
    loggingService.log("Checked lifetime status: $hasLifetime");
  }

  Future<void> _loadApiKey() async {
    String? storedKey = await storage.read(key: "OPENAI_API_KEY");
    if (storedKey != null && storedKey.isNotEmpty) {
      await openAIService.setApiKey(storedKey);
      setState(() {
        apiKey = storedKey;
        currentStep = 0;
      });
    }
  }

  bool _isPurchasing = false;

  Future<void> _purchase(String productKey) async {
    if (_isPurchasing) {
      loggingService.log("Purchase already in progress, ignoring: $productKey");
      return;
    }
    _isPurchasing = true;
    try {
      if (productKey == "monthly" || productKey == "yearly") {
        final hasLifetime = await purchaseService.hasLifetime();
        if (hasLifetime) {
          loggingService.log("Subscription purchase rejected: Lifetime access already purchased.");
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("You already have lifetime access. Subscription not needed."),
            ),
          );
          return;
        }
      }

      if (productKey == "lifetime") {
        final hasSubscription = await purchaseService.hasValidSubscription();
        if (hasSubscription) {
          final bool? shouldContinue = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text("Active Subscription Detected"),
              content: const Text(
                "You have an active subscription. "
                "Purchasing a lifetime license will make the subscription unnecessary. "
                "You can cancel your subscription in the Google Play Store if you proceed. "
                "Do you want to continue with the lifetime purchase?",
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text("Cancel"),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text("Continue"),
                ),
              ],
            ),
          );
          if (shouldContinue != true) {
            loggingService.log("Lifetime purchase aborted due to active subscription.");
            return;
          }
        }
      }

      final productId = getProductId(productKey);
      loggingService.log("Purchase started: $productId (productKey=$productKey)");

      if (!_productDetails.containsKey(productId) || _productDetails[productId]!.isEmpty) {
        loggingService.error("Product not loaded: $productId (productKey=$productKey)");
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Product not loaded")),
        );
        return;
      }

      ProductDetails selectedDetails;
      if (productId == subscriptionId) {
        if (productKey == "monthly") {
          selectedDetails = _productDetails[productId]!.firstWhere(
            (pd) => pd.rawPrice == 1.99,
            orElse: () {
              loggingService.error("Monthly plan (\$1.99) not found for $productId. Available prices: ${_productDetails[productId]!.map((pd) => pd.rawPrice).toList()}");
              return _productDetails[productId]!.first;
            },
          );
        } else if (productKey == "yearly") {
          selectedDetails = _productDetails[productId]!.firstWhere(
            (pd) => pd.rawPrice == 19.99,
            orElse: () {
              loggingService.error("Yearly plan (\$19.99) not found for $productId. Available prices: ${_productDetails[productId]!.map((pd) => pd.rawPrice).toList()}");
              return _productDetails[productId]!.first;
            },
          );
        } else {
          loggingService.error("Invalid productKey for subscription: $productKey");
          selectedDetails = _productDetails[productId]!.first;
        }
      } else {
        selectedDetails = _productDetails[productId]!.first;
      }

      loggingService.log("Selected ProductDetails: id=${selectedDetails.id}, price=${selectedDetails.price}, rawPrice=${selectedDetails.rawPrice}");

      final purchaseParam = PurchaseParam(productDetails: selectedDetails);

      try {
        if (productId == lifetimePlanId) {
          loggingService.log("Buying non-consumable product: $productId");
          await _iap.buyNonConsumable(purchaseParam: purchaseParam);
        } else {
          loggingService.log("Buying subscription: $productId (productKey=$productKey, price=${selectedDetails.price})");
          await _iap.buyConsumable(purchaseParam: purchaseParam, autoConsume: false);
        }
        loggingService.log("Purchase request sent for: $productId (productKey=$productKey, price=${selectedDetails.price})");
      } catch (e, stack) {
        loggingService.error("Purchase failed for $productId (productKey=$productKey): $e\n$stack");
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Purchase failed: $e")),
        );
      }
    } finally {
      _isPurchasing = false;
    }
  }

  Future<void> _loadProducts() async {
    final bool isAvailable = await _iap.isAvailable();
    if (!isAvailable) {
      loggingService.error("Google Play Billing is not available on this device");
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Billing service unavailable")),
      );
      return;
    }

    final Set<String> inAppIds = useTestIds
        ? {testPurchasedId, testCanceledId, testRefundedId, testUnavailableId}
        : {lifetimePlanId};

    final Set<String> subscriptionIds = useTestIds ? <String>{} : {subscriptionId};

    loggingService.log("Starting product load...");

    _productDetails.clear();
    _productDetails[lifetimePlanId] = [];
    _productDetails[subscriptionId] = [];

    if (inAppIds.isNotEmpty) {
      loggingService.log("Querying in-app products: $inAppIds");
      final inAppResponse = await _iap.queryProductDetails(inAppIds);

      if (inAppResponse.error != null) {
        loggingService.error("Error querying in-app products: ${inAppResponse.error!.message}");
      }
      if (inAppResponse.notFoundIDs.isNotEmpty) {
        loggingService.error("In-App Products not found: ${inAppResponse.notFoundIDs}");
      }

      for (var pd in inAppResponse.productDetails) {
        _productDetails[pd.id]!.add(pd);
        loggingService.log("In-App product loaded: ${pd.id} (${pd.title}, ${pd.price})");
        loggingService.log("ProductDetails for ${pd.id}: id=${pd.id}, title=${pd.title}, description=${pd.description}, price=${pd.price}, rawPrice=${pd.rawPrice}, currencyCode=${pd.currencyCode}");
      }
    }

    if (subscriptionIds.isNotEmpty) {
      loggingService.log("Querying subscriptions: $subscriptionIds");
      final subResponse = await _iap.queryProductDetails(subscriptionIds);

      if (subResponse.error != null) {
        loggingService.error("Error querying subscriptions: ${subResponse.error!.message}");
      }
      if (subResponse.notFoundIDs.isNotEmpty) {
        loggingService.error("Subscriptions not found: ${subResponse.notFoundIDs}");
      }

      for (var pd in subResponse.productDetails) {
        _productDetails[pd.id]!.add(pd);
        loggingService.log("Subscription loaded: ${pd.id} (${pd.title}, ${pd.price})");
        loggingService.log("ProductDetails for ${pd.id}: id=${pd.id}, title=${pd.title}, description=${pd.description}, price=${pd.price}, rawPrice=${pd.rawPrice}, currencyCode=${pd.currencyCode}");
      }
    }

    _productDetails.forEach((id, detailsList) {
      loggingService.log("Stored ProductDetails for $id: ${detailsList.map((pd) => 'price=${pd.price}, rawPrice=${pd.rawPrice}').toList()}");
    });

    loggingService.log("Product loading complete.");
  }

  Future<void> _handlePurchase(PurchaseDetails purchase) async {
    loggingService.log("📥 Handling purchase: productId=${purchase.productID}, status=${purchase.status}");
    loggingService.log("PurchaseDetails: id=${purchase.productID}, status=${purchase.status}, transactionDate=${purchase.transactionDate}, purchaseID=${purchase.purchaseID}");

    try {
      if (purchase.status != PurchaseStatus.purchased && purchase.status != PurchaseStatus.restored) {
        loggingService.error("Purchase not completed: status=${purchase.status}");
        return;
      }

      if (purchase.productID == lifetimePlanId) {
        loggingService.log("Granting lifetime unlock.");
        await purchaseService.setLifetime(true);
        setState(() {
          isLifetimePurchased = true;
        });
        loggingService.log("Updated isLifetimePurchased to true after lifetime purchase.");
      } else if (purchase.productID == subscriptionId) {
        final productDetails = _productDetails[purchase.productID]?.firstWhere(
          (pd) => pd.rawPrice == 1.99 || pd.rawPrice == 19.99,
          orElse: () => _productDetails[purchase.productID]!.first,
        );
        if (productDetails != null && productDetails.rawPrice == 1.99) {
          loggingService.log("Extending subscription by 30 days (monthly plan, price=${productDetails.price}).");
          await purchaseService.extendSubscription(days: 30);
        } else if (productDetails != null && productDetails.rawPrice == 19.99) {
          loggingService.log("Extending subscription by 365 days (yearly plan, price=${productDetails.price}).");
          await purchaseService.extendSubscription(days: 365);
        } else {
          loggingService.error("Unknown price for subscription: ${productDetails?.price ?? 'null'}");
          loggingService.log("Extending subscription by 30 days (fallback, price=${productDetails?.price ?? 'unknown'}).");
          await purchaseService.extendSubscription(days: 30);
        }
      }

      if (purchase.pendingCompletePurchase) {
        loggingService.log("Completing pending purchase for ${purchase.productID}");
        await _iap.completePurchase(purchase);
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Purchase successful! App unlocked.")),
      );

      setState(() {
        currentStep = 4;
        loggingService.log("UI updated after purchase: currentStep=$currentStep, isLifetimePurchased=$isLifetimePurchased");
      });

      loggingService.log("🎉 Purchase flow finished successfully for ${purchase.productID}");
    } catch (e, st) {
      loggingService.error("🔥 Exception in _handlePurchase: $e");
      loggingService.error(st.toString());
    }
  }

  Future<void> checkPastPurchases() async {
    try {
      loggingService.log("Starting restorePurchases...");
      final bool isAvailable = await _iap.isAvailable();
      if (!isAvailable) {
        loggingService.error("Google Play Billing is not available on this device");
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Billing service unavailable")),
        );
        return;
      }

      bool hasLifetime = false;
      final completer = Completer<void>();
      late final StreamSubscription<List<PurchaseDetails>> tempSubscription;

      tempSubscription = _iap.purchaseStream.listen(
        (purchases) async {
          loggingService.log("Received ${purchases.length} restored purchases");
          for (var purchase in purchases) {
            loggingService.log("Restored purchase: productId=${purchase.productID}, status=${purchase.status}");
            if (purchase.productID == lifetimePlanId &&
                (purchase.status == PurchaseStatus.purchased || purchase.status == PurchaseStatus.restored)) {
              hasLifetime = true;
              await _handlePurchase(purchase);
            }
          }
          if (!completer.isCompleted) {
            completer.complete();
          }
        },
        onDone: () {
          loggingService.log("Restore purchases stream closed.");
          tempSubscription.cancel();
          if (!completer.isCompleted) {
            completer.complete();
          }
        },
        onError: (error) {
          loggingService.error("Error during restorePurchases: $error");
          if (!completer.isCompleted) {
            completer.complete();
          }
        },
      );

      await _iap.restorePurchases();
      await completer.future;

      if (!hasLifetime) {
        loggingService.log("No valid lifetime purchase found. Clearing lifetime status.");
        await purchaseService.setLifetime(false);
        setState(() {
          isLifetimePurchased = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("No valid purchases found. Lifetime access cleared.")),
        );
      }

      loggingService.log("restorePurchases completed. hasLifetime: $hasLifetime");
      tempSubscription.cancel();
    } catch (e, st) {
      loggingService.error("Error restoring purchases: $e\nStackTrace: $st");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error restoring purchases: $e")),
      );
    }
  }

  void onPurchase(String productKey) {
    _purchase(productKey);
  }

  Future<bool> _checkAccess() async {
    final startStr = await purchaseService.getTrialStart();
    if (startStr == null) {
      await purchaseService.startTrial();
    }
    return await purchaseService.isEntitled();
  }

  void _setTrialDateForTesting() async {
    final daysAgo = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Set Trial Start Date (Test Only)"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("Choose days ago for trial start:"),
            const SizedBox(height: 10),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, 0),
              child: const Text("Today (14 days remaining)"),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, 13),
              child: const Text("13 days ago (1 day remaining)"),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, 15),
              child: const Text("15 days ago (expired)"),
            ),
          ],
        ),
      ),
    );

    if (daysAgo != null) {
      final trialStart = DateTime.now().subtract(Duration(days: daysAgo)).toIso8601String();
      await purchaseService.setTrialStart(trialStart);
      loggingService.log("Trial start set to $trialStart for testing (days ago: $daysAgo)");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Trial start set to $daysAgo days ago")),
      );
      setState(() {}); // Trigger rebuild to reflect new trial status
    }
  }

  void configureServices(String key) async {
    await openAIService.setApiKey(key);
    await storage.write(key: "OPENAI_API_KEY", value: key);
    setState(() {
      apiKey = key;
      currentStep = 4;
    });
  }

  void clearApiKey() async {
    await storage.delete(key: "OPENAI_API_KEY");
    setState(() {
      apiKey = "";
      currentStep = 2;
    });
  }

  void nextStep() {
    setState(() {
      if (currentStep != null) {
        currentStep = currentStep! + 1;
      }
    });
  }

  void prevStep() {
    setState(() {
      if (currentStep != null) {
        currentStep = currentStep! - 1;
      }
    });
  }

  Future<void> pickPdfs() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
      allowMultiple: true,
    );

    if (result != null && result.files.isNotEmpty) {
      setState(() {
        pdfPaths = result.paths.whereType<String>().toList();
      });

      for (var path in pdfPaths) {
        await pdfService.processPdf(path);
      }
    }
  }

  Future<File?> saveLogToDownloads() async {
    try {
      final logFile = await loggingService.saveToFile();

      if (Platform.isAndroid) {
        if (!await perm.Permission.storage.request().isGranted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Storage permission denied")),
          );
          return null;
        }
        final downloadsDir = Directory('/storage/emulated/0/Download');
        final targetPath = '${downloadsDir.path}/pai_logs.txt';
        final targetFile = await logFile.copy(targetPath);
        return targetFile;
      } else if (Platform.isIOS) {
        final dir = await getApplicationDocumentsDirectory();
        final targetPath = '${dir.path}/pai_logs.txt';
        final targetFile = await logFile.copy(targetPath);
        return targetFile;
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error saving log: $e")),
      );
      return null;
    }
    return null;
  }

  Future<void> sendLogByEmail() async {
    final file = await saveLogToDownloads();
    if (file == null) return;

    final Uri emailUri = Uri(
      scheme: 'mailto',
      path: 'admin@paidocassistant.com',
      queryParameters: {
        'subject': 'PAI App Logs',
        'body': 'Attached are my logs for troubleshooting.',
      },
    );

    if (await canLaunchUrl(emailUri)) {
      await launchUrl(emailUri);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not launch email app')),
      );
    }
  }

  void sendMessage() async {
    final query = queryController.text.trim();
    if (query.isEmpty) return;

    setState(() {
      chatHistory.add({"role": "user", "text": query});
      chatHistory.add({"role": "pai", "text": "Thinking..."});

      if (!previousQuestions.contains(query)) {
        previousQuestions.add(query);
      }

      queryController.clear();
    });

    await Future.delayed(const Duration(milliseconds: 100));
    chatScrollController.jumpTo(chatScrollController.position.maxScrollExtent);

    try {
      final answer = await askService.ask(
        query: query,
        limitContext: limitContext,
      );

      setState(() {
        chatHistory.removeLast();
        chatHistory.add({"role": "pai", "text": answer});
      });

      await Future.delayed(const Duration(milliseconds: 100));
      chatScrollController.jumpTo(chatScrollController.position.maxScrollExtent);
    } catch (e) {
      setState(() {
        chatHistory.removeLast();
        chatHistory.add({"role": "pai", "text": "Error: $e"});
      });
      await Future.delayed(const Duration(milliseconds: 100));
      chatScrollController.jumpTo(chatScrollController.position.maxScrollExtent);
    }
  }

  void exitApp() async {
    await dbService.clear();
    if (Platform.isAndroid || Platform.isIOS) {
      exit(0);
    }
  }

  @override
  void dispose() {
    _trialTimer?.cancel();
    _subscription.cancel();
    dbService.clear();
    queryController.dispose();
    super.dispose();
  }

  Widget _buildUpgradeScreen(int daysLeft) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          isLifetimePurchased
              ? "You have lifetime access! No further purchase is needed."
              : daysLeft > 0
                  ? "Your free trial has $daysLeft day${daysLeft > 1 ? 's' : ''} remaining.\n\nUpgrade to continue using the app:"
                  : "Your free trial has ended.\n\nUpgrade to continue using the app:",
          style: const TextStyle(fontSize: 16),
        ),
        const SizedBox(height: 20),
        if (!isLifetimePurchased) ...[
          ElevatedButton(
            onPressed: () => _purchase("monthly"),
            child: const Text("\$1.99 / month"),
          ),
          ElevatedButton(
            onPressed: () => _purchase("yearly"),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blueAccent,
            ),
            child: const Text("\$19.99 / year  ⭐ Most Popular"),
          ),
        ],
        ElevatedButton(
          onPressed: isLifetimePurchased ? null : () => _purchase("lifetime"),
          child: const Text("\$49.99 Lifetime"),
        ),
        const SizedBox(height: 20),
        ElevatedButton(
          onPressed: () async {
            await checkPastPurchases();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text("Restoring purchases...")),
            );
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.grey.shade300,
            foregroundColor: Colors.black,
          ),
          child: const Text("Restore Purchases"),
        ),
        const SizedBox(height: 20),
        ElevatedButton(
          onPressed: _setTrialDateForTesting,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.orange,
            foregroundColor: Colors.black,
          ),
          child: const Text("Set Trial Date (Test Only)"),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final steps = [
      _buildStepCard(
        step: 0,
        title: "Disclaimer",
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "This software is for informational purposes only.\n\n"
                "• It does NOT provide medical advice, diagnosis, or treatment.\n"
                "• It does NOT provide legal advice about Medicare, Medicaid, disability, or other benefits.\n"
                "• Always consult a qualified professional before making decisions.\n"
                "• All processing happens locally on your device. No data is sent to us.",
                style: TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 20),
              ExpansionTile(
                title: const Text(
                  "View Terms of Use",
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.blue,
                  ),
                ),
                onExpansionChanged: (expanded) {
                  setState(() {
                    termsExpanded = expanded;
                  });
                },
                children: const [
                  Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      "Terms of Use (Effective Sept 18, 2025)\n\n"
                      "1. License: You are granted a limited, non-exclusive license to use this app. "
                      "You may not redistribute, resell, or reverse engineer it.\n\n"
                      "2. No Advice: This app is informational only and does not provide medical, legal, "
                      "or financial advice. Always consult a professional.\n\n"
                      "3. Privacy: Documents are processed locally on your device. No data is sent to us.\n\n"
                      "4. Purchases: Ads, subscriptions, or in-app purchases may apply. All sales final "
                      "unless required by law.\n\n"
                      "5. Disclaimer: The app is provided 'as-is' without warranties. We are not liable "
                      "for damages or losses from its use.\n\n"
                      "6. Governing Law: These terms are governed by U.S. law.\n\n"
                      "© 2025 Christopher Petitpas. All rights reserved.",
                      style: TextStyle(fontSize: 14),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Center(
                child: ElevatedButton(
                  onPressed: termsExpanded
                      ? () {
                          if (apiKey.isNotEmpty) {
                            setState(() => currentStep = 4);
                          } else {
                            nextStep();
                          }
                        }
                      : null,
                  child: const Text("I Understand"),
                ),
              ),
            ],
          ),
        ),
      ),
      _buildStepCard(
        step: 1,
        title: "Welcome to PAI Assistant - Document Clarity AI",
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Text(
                "Welcome to PAI your Personal AI Document Assistant!\n\n"
                "With this application you can upload PDF documents and ask questions about their content.\n\n"
                "This is very helpful with documents which come from Social Security, Medicare, Insurance, Legal, Medical, wherein the language is complex and difficult to understand.\n\n"
                "It is also helpful when you have many documents and one seems to conflict with another.\n\n"
                "If you have issues you can always send logs via the email icon in the top-right.\n\n"
                "Free trial for 14 days, then \$1.99/month or \$19.99/year. Lifetime option also available.\n\n",
                style: TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: nextStep,
                child: const Text("Next"),
              ),
              FutureBuilder<int>(
                future: purchaseService.remainingTrialDays(),
                builder: (context, snapshot) {
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  return TextButton(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => UpgradePage(
                            trialDaysRemaining: snapshot.data!,
                            onPurchase: _purchase,
                            isLifetimePurchased: isLifetimePurchased,
                            onRestorePurchases: checkPastPurchases,
                            onSetTrialDate: _setTrialDateForTesting,
                          ),
                        ),
                      );
                    },
                    child: const Text("Upgrade Now"),
                  );
                },
              ),
            ],
          ),
        ),
      ),
      _buildStepCard(
        step: 2,
        title: "Getting Started: OpenAI API Key",
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Text(
                "This application leverages the power of OpenAI's GPT models to provide accurate and context-aware answers based on your documents.\n\n"
                "You will need an OpenAI API key to use this application.\n\n"
                "You can sign up or log in to your OpenAI account, then create a secret key and copy it to your clipboard.\n\n"
                "⚠️ Note: You will have only one opportunity to copy the key, so save it somewhere safe.\n\n"
                "The key will be stored securely on your device and never shared.\n\n"
                "Once set, this step will be skipped on future app launches.\n\n"
                "If you need to change or remove the key, you can do so later from the top-right key icon.\n\n"
                "You will get some free credits from OpenAI when you sign up. After that you will need to add some credits to your account via the Billing page.\n\n"
                "The API costs are very low, especially if you enable the 'Limit Context' option in the final step. \$5 can last a long time!\n\n",
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                icon: const Icon(Icons.open_in_browser),
                label: const Text("Open OpenAI API Key Page"),
                onPressed: () async {
                  final Uri url = Uri.parse("https://platform.openai.com/account/api-keys");
                  if (await canLaunchUrl(url)) {
                    try {
                      await launchUrl(url, mode: LaunchMode.externalApplication);
                    } catch (e) {
                      await launchUrl(url, mode: LaunchMode.platformDefault);
                    }
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text("Cannot launch URL")),
                    );
                  }
                },
              ),
              const SizedBox(height: 8),
              SelectableText(
                "https://platform.openai.com/account/api-keys",
                style: const TextStyle(
                  color: Colors.blue,
                  decoration: TextDecoration.underline,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  OutlinedButton(onPressed: prevStep, child: const Text("Back")),
                  ElevatedButton(onPressed: nextStep, child: const Text("Continue")),
                ],
              ),
            ],
          ),
        ),
      ),
      _buildStepCard(
        step: 3,
        title: "Enter OpenAI API Key",
        content: Column(
          children: [
            TextField(
              onChanged: (v) => apiKey = v,
              decoration: const InputDecoration(
                labelText: "OPENAI_API_KEY",
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                OutlinedButton(onPressed: prevStep, child: const Text("Back")),
                ElevatedButton(
                  onPressed: () {
                    if (apiKey.isNotEmpty) {
                      configureServices(apiKey);
                    }
                  },
                  child: const Text("Next"),
                ),
              ],
            ),
          ],
        ),
      ),
      _buildStepCard(
        step: 4,
        title: "Select PDFs",
        content: Column(
          children: [
            ElevatedButton.icon(
              onPressed: pickPdfs,
              icon: const Icon(Icons.upload_file),
              label: const Text("Pick PDF files"),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: () async {
                await dbService.clear();
                setState(() {
                  pdfPaths.clear();
                });
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Database cleared")),
                );
              },
              icon: const Icon(Icons.delete_forever, color: Colors.red),
              label: const Text("Clear Database"),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: pdfPaths.isEmpty
                  ? const Center(child: Text("No PDFs selected"))
                  : ListView.builder(
                      itemCount: pdfPaths.length,
                      itemBuilder: (context, i) {
                        return ListTile(
                          leading: const Icon(Icons.picture_as_pdf, color: Colors.red),
                          title: Text(pdfPaths[i].split('/').last),
                          subtitle: Text(pdfPaths[i]),
                        );
                      },
                    ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                OutlinedButton(onPressed: prevStep, child: const Text("Back")),
                ElevatedButton(
                  onPressed: pdfPaths.isNotEmpty ? nextStep : null,
                  child: const Text("Next"),
                ),
              ],
            ),
          ],
        ),
      ),
      _buildStepCard(
        step: 5,
        title: "Ask Questions",
        content: Column(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  onTap: () {
                    setState(() {
                      showLimitContextInfo = !showLimitContextInfo;
                    });
                  },
                  child: Row(
                    children: [
                      Text(
                        "Limit Context Info",
                        style: TextStyle(
                          color: Colors.blue,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Icon(
                        showLimitContextInfo
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                        color: Colors.blue,
                      ),
                    ],
                  ),
                ),
                if (showLimitContextInfo)
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                    margin: const EdgeInsets.only(bottom: 8, top: 4),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      "Limit Context controls how much of your documents are used to answer your question.\n\n"
                      "• ON (recommended): Only the most relevant parts of your PDFs are used, making answers faster and more focused.\n"
                      "• OFF: The AI considers all content from your PDFs, which may be slower but can provide broader answers.\n\n"
                      "You can toggle this setting at any time.",
                      style: TextStyle(fontSize: 15, color: Colors.black87),
                    ),
                  ),
              ],
            ),
            Expanded(
              child: ListView.builder(
                controller: chatScrollController,
                itemCount: chatHistory.length,
                itemBuilder: (context, i) {
                  final msg = chatHistory[i];
                  final isUser = msg["role"] == "user";
                  return Align(
                    alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                      decoration: BoxDecoration(
                        color: isUser ? Colors.blue : Colors.green,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        msg["text"]!,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey.shade400),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          children: [
                            TextField(
                              controller: queryController,
                              decoration: const InputDecoration(
                                hintText: "Ask something...",
                                border: InputBorder.none,
                              ),
                              textInputAction: TextInputAction.send,
                              onChanged: (value) {
                                setState(() {
                                  showPreviousQuestions = value.isEmpty;
                                });
                              },
                              onTap: () {
                                setState(() {
                                  showPreviousQuestions = queryController.text.isEmpty;
                                });
                              },
                              onSubmitted: (_) => sendMessage(),
                            ),
                            if (showPreviousQuestions && previousQuestions.isNotEmpty)
                              Container(
                                constraints: const BoxConstraints(maxHeight: 150),
                                margin: const EdgeInsets.only(top: 6),
                                child: ListView.builder(
                                  shrinkWrap: true,
                                  itemCount: previousQuestions.length,
                                  itemBuilder: (context, i) {
                                    final q = previousQuestions[i];
                                    return ListTile(
                                      dense: true,
                                      title: Text(
                                        q,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      onTap: () {
                                        setState(() {
                                          queryController.text = q;
                                          showPreviousQuestions = false;
                                        });
                                        sendMessage();
                                      },
                                    );
                                  },
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: sendMessage,
                  child: const Text("Ask"),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                OutlinedButton(onPressed: prevStep, child: const Text("Back")),
                Row(
                  children: [
                    Text(
                      "Limit Context",
                      style: TextStyle(
                        color: limitContext ? Colors.blue : Colors.grey,
                        fontWeight: limitContext ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: () {
                        setState(() => limitContext = !limitContext);
                        loggingService.log(
                          "User toggled context mode: ${limitContext ? "Limited" : "Flexible"}",
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: limitContext ? Colors.blue : Colors.grey,
                      ),
                      child: Text(limitContext ? "ON" : "OFF"),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    ];

    Widget content = FutureBuilder<bool>(
      future: _checkAccess(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final entitled = snapshot.data ?? false;

        if (!entitled) {
          return FutureBuilder<int>(
            future: purchaseService.remainingTrialDays(),
            builder: (context, trialSnap) {
              if (!trialSnap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              return _buildUpgradeScreen(trialSnap.data ?? 0);
            },
          );
        } else {
          final safeStep = (currentStep ?? 0).clamp(0, steps.length - 1);
          return steps[safeStep];
        }
      },
    );

    return Scaffold(
      backgroundColor: Colors.blue,
      appBar: AppBar(
        title: const Text("PAI Assistant - Document Clarity AI"),
        backgroundColor: Colors.blue.shade700,
        actions: [
          if (currentStep != null && currentStep! > 0) ...[
            Tooltip(
              message: "Clear saved OpenAI API Key",
              child: IconButton(
                icon: const Icon(Icons.key_off),
                onPressed: clearApiKey,
              ),
            ),
            Tooltip(
              message: "Exit App",
              child: IconButton(
                icon: const Icon(Icons.exit_to_app),
                onPressed: exitApp,
              ),
            ),
          ],
          Tooltip(
            message: "Download log file",
            child: IconButton(
              icon: const Icon(Icons.download),
              onPressed: () async {
                try {
                  final logFile = await loggingService.saveToFile();
                  await Share.shareXFiles(
                    [XFile(logFile.path)],
                    text: "PAI App Logs",
                    subject: "PAI Logs",
                  );
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        "Select 'Save to Files' or your preferred app to store the log.",
                      ),
                      duration: Duration(seconds: 4),
                    ),
                  );
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text("Failed to save log: $e")),
                  );
                }
              },
            ),
          ),
          Tooltip(
            message: "Send logs via email",
            child: IconButton(
              icon: const Icon(Icons.email),
              onPressed: () async {
                try {
                  final logFile = await loggingService.saveToFile();
                  await Share.shareXFiles(
                    [XFile(logFile.path)],
                    text: "Here are my logs for troubleshooting.\n\nPlease send to admin@paidocassistant.com",
                    subject: "PAI App Logs",
                  );
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        "Select your email app and verify the recipient before sending.",
                      ),
                      duration: Duration(seconds: 4),
                    ),
                  );
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text("Failed to send logs: $e")),
                  );
                }
              },
            ),
          ),
        ],
      ),
      body: Container(
        margin: const EdgeInsets.all(16),
        child: Column(
          children: [
            if (currentStep != null && currentStep! > 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    Image.asset(
                      "assets/images/robot.png",
                      width: 40,
                      height: 40,
                    ),
                    const SizedBox(width: 12),
                    const Text(
                      "PAI Assistant - Document Clarity AI",
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: Center(
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 600),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: const [BoxShadow(blurRadius: 6, color: Colors.black26)],
                  ),
                  child: content,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStepCard({
    required int step,
    required String title,
    required Widget content,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (step > 0)
          Text(
            "Step $step",
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: Colors.blue,
            ),
          ),
        if (step > 0) const SizedBox(height: 8),
        Text(
          title,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 16),
        Expanded(child: content),
      ],
    );
  }
}
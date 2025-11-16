// main.dart
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:webfeed/webfeed.dart';
import 'package:intl/intl.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:share_plus/share_plus.dart';
import 'package:photo_view/photo_view.dart';
import 'dart:async';
import 'package:url_launcher/url_launcher.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FeedFlowApp());
}

class FeedFlowApp extends StatelessWidget {
  const FeedFlowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Reeds',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
        primaryColor: const Color(0xFFFF9500),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.black,
          elevation: 0,
          centerTitle: false,
          titleTextStyle: TextStyle(
            color: Color(0xFFFF9500),
            fontSize: 28,
            fontWeight: FontWeight.bold,
          ),
        ),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: Colors.black,
          selectedItemColor: Color(0xFFFF9500),
          unselectedItemColor: Color(0xFF666666),
          type: BottomNavigationBarType.fixed,
          elevation: 0,
        ),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFFF9500),
          secondary: Color(0xFF666666),
          surface: Colors.black,
        ),
      ),
      home: const FeedHomePage(),
    );
  }
}

// Models
class FeedSource {
  final String name;
  final String url;
  final String category;

  FeedSource({required this.name, required this.url, required this.category});
}

class FeedItem {
  final String id;
  final String feedSource;
  final String feedSourceImage;
  final String title;
  final String description;
  final String author;
  final DateTime date;
  final String link;
  final String? image;

  FeedItem({
    required this.id,
    required this.feedSource,
    required this.feedSourceImage,
    required this.title,
    required this.description,
    required this.author,
    required DateTime date,
    required this.link,
    this.image,
  }) : date = date.isUtc ? date.toLocal() : date;

  Map<String, dynamic> toJson() => {
    'id': id,
    'feedSource': feedSource,
    'feedSourceImage': feedSourceImage,
    'title': title,
    'description': description,
    'author': author,
    'date': date.toIso8601String(),
    'link': link,
    'image': image,
  };

  factory FeedItem.fromJson(Map<String, dynamic> json) {
    return FeedItem(
      id: json['id'],
      feedSource: json['feedSource'],
      feedSourceImage: json['feedSourceImage'],
      title: json['title'],
      description: json['description'],
      author: json['author'],
      date: DateTime.parse(json['date']),
      link: json['link'],
      image: json['image'],
    );
  }
}

class FeedHomePage extends StatefulWidget {
  const FeedHomePage({super.key});

  @override
  State<FeedHomePage> createState() => _FeedHomePageState();
}

class _FeedHomePageState extends State<FeedHomePage> {
  int _currentIndex = 0;
  List<FeedSource> allFeedSources = [];
  Set<String> selectedSourceUrls = {};
  final List<FeedItem> _feedItems = [];
  List<FeedItem> savedItems = [];
  bool isLoading = true;
  bool isRefreshing = false;
  Set<String> expandedCategories = {};

  String? selectedCategory;
  String? selectedFeedSource;

  final ScrollController _homeScrollController = ScrollController();
  final ScrollController _savedScrollController = ScrollController();

  int _loadedFeedsCount = 0;
  int _totalFeedsToLoad = 0;

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  @override
  void dispose() {
    _homeScrollController.dispose();
    _savedScrollController.dispose();
    super.dispose();
  }

  Future<void> _initializeApp() async {
    await Future.wait([
      loadFeedSources(),
      loadSavedItems(),
      loadCustomSources(),
    ]);
  }

  // Feed Sources Management
  Future<void> loadFeedSources() async {
    try {
      final response = await http.get(
        Uri.parse('https://soheshts.github.io/feedflow/feeds.json'),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        final sources = <FeedSource>[];

        data.forEach((category, feeds) {
          for (var feed in feeds as List) {
            sources.add(
              FeedSource(
                name: feed['name'],
                url: feed['url'],
                category: category,
              ),
            );
          }
        });

        setState(() {
          allFeedSources = sources;
          isLoading = false;
        });

        await loadSelectedSources();

        if (selectedSourceUrls.isEmpty && sources.isNotEmpty) {
          setState(() {
            selectedSourceUrls = {
              sources[0].url,
              if (sources.length > 1) sources[1].url,
              if (sources.length > 2) sources[2].url,
            };
          });
          await saveSelectedSources();
        }

        loadFeedsProgressively();
      }
    } catch (e) {
      debugPrint('Error loading feed sources: $e');
      setState(() => isLoading = false);
    }
  }

  Future<void> loadCustomSources() async {
    final prefs = await SharedPreferences.getInstance();
    final customSourcesJson = prefs.getStringList('custom_sources');
    if (customSourcesJson != null) {
      final customSources = customSourcesJson.map((jsonStr) {
        final map = jsonDecode(jsonStr);
        return FeedSource(
          name: map['name'],
          url: map['url'],
          category: 'custom',
        );
      }).toList();

      setState(() => allFeedSources.addAll(customSources));
    }
  }

  Future<void> saveCustomSources() async {
    final prefs = await SharedPreferences.getInstance();
    final customSources = allFeedSources
        .where((source) => source.category == 'custom')
        .map((source) => jsonEncode({'name': source.name, 'url': source.url}))
        .toList();
    await prefs.setStringList('custom_sources', customSources);
  }

  Future<void> addCustomSource(String name, String url) async {
    try {
      Uri.parse(url);
    } catch (e) {
      _showSnackBar('Invalid URL format');
      return;
    }

    if (allFeedSources.any((source) => source.url == url)) {
      _showSnackBar('This feed already exists');
      return;
    }

    final newSource = FeedSource(
      name: name.isEmpty ? 'Custom Feed' : name,
      url: url,
      category: 'custom',
    );

    setState(() {
      allFeedSources.add(newSource);
      selectedSourceUrls.add(url);
      expandedCategories.add('custom');
    });

    await Future.wait([saveCustomSources(), saveSelectedSources()]);
    await loadFeedsProgressively();
    _showSnackBar('Custom feed added successfully');
  }

  Future<void> deleteCustomSource(String url) async {
    setState(() {
      allFeedSources.removeWhere(
        (source) => source.url == url && source.category == 'custom',
      );
      selectedSourceUrls.remove(url);
      _feedItems.removeWhere(
        (item) =>
            allFeedSources
                .firstWhere(
                  (s) => s.name == item.feedSource,
                  orElse: () => FeedSource(name: '', url: url, category: ''),
                )
                .url ==
            url,
      );
    });

    await Future.wait([saveCustomSources(), saveSelectedSources()]);
    _showSnackBar('Custom feed removed');
  }

  Future<void> loadSelectedSources() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList('selected_sources');
    if (saved != null) {
      setState(() => selectedSourceUrls = saved.toSet());
    }
  }

  Future<void> saveSelectedSources() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('selected_sources', selectedSourceUrls.toList());
  }

  // Saved Items Management
  Future<void> loadSavedItems() async {
    final prefs = await SharedPreferences.getInstance();
    final savedJson = prefs.getStringList('saved_items');
    if (savedJson != null) {
      setState(() {
        savedItems = savedJson
            .map((jsonStr) => FeedItem.fromJson(jsonDecode(jsonStr)))
            .toList();
      });
    }
  }

  Future<void> saveFeedItem(FeedItem item) async {
    final prefs = await SharedPreferences.getInstance();

    setState(() {
      if (savedItems.any((saved) => saved.id == item.id)) {
        savedItems.removeWhere((saved) => saved.id == item.id);
      } else {
        savedItems.add(item);
      }
    });

    final savedJson = savedItems
        .map((item) => jsonEncode(item.toJson()))
        .toList();
    await prefs.setStringList('saved_items', savedJson);
  }

  bool isItemSaved(String itemId) =>
      savedItems.any((item) => item.id == itemId);

  // Feed Loading
  Future<void> loadFeedsProgressively() async {
    setState(() {
      isRefreshing = true;
      _feedItems.clear();
      _loadedFeedsCount = 0;
      _totalFeedsToLoad = selectedSourceUrls.length;
    });

    final seenIds = <String>{};

    for (var url in selectedSourceUrls) {
      if (!mounted) break;

      try {
        final feedData = await fetchAndParseFeed(url);
        if (mounted) {
          setState(() {
            for (var item in feedData) {
              if (!seenIds.contains(item.id)) {
                seenIds.add(item.id);
                _feedItems.add(item);
              }
            }
            _feedItems.sort((a, b) => b.date.compareTo(a.date));
            _loadedFeedsCount++;
          });
        }
      } catch (e) {
        debugPrint('Error loading feed $url: $e');
        if (mounted) setState(() => _loadedFeedsCount++);
      }
    }

    if (mounted) setState(() => isRefreshing = false);
  }

  Future<List<FeedItem>> fetchAndParseFeed(String url) async {
    try {
      final response = await http
          .get(
            Uri.parse(url),
            headers: {
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
              'Accept':
                  'application/rss+xml, application/atom+xml, application/xml, text/xml, */*',
              'Accept-Encoding': 'gzip, deflate',
            },
          )
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () => throw TimeoutException('Feed request timeout'),
          );

      if (response.statusCode == 200) {
        String feedContent;
        try {
          feedContent = utf8.decode(response.bodyBytes, allowMalformed: true);
        } catch (e) {
          feedContent = response.body;
        }

        // Clean up any potential XML issues
        feedContent = feedContent.trim();

        try {
          return parseRssFeed(RssFeed.parse(feedContent), url);
        } catch (rssError) {
          debugPrint('RSS parse error for $url: $rssError');
          try {
            return parseAtomFeed(AtomFeed.parse(feedContent), url);
          } catch (atomError) {
            debugPrint('Atom parse error for $url: $atomError');
            return [];
          }
        }
      } else {
        debugPrint('HTTP error ${response.statusCode} for $url');
      }
    } catch (e) {
      debugPrint('Error fetching feed $url: $e');
    }
    return [];
  }

  DateTime _parseDateTime(DateTime? dateTime) {
    if (dateTime == null) return DateTime.now();
    return dateTime.isUtc ? dateTime.toLocal() : dateTime;
  }

  List<FeedItem> parseRssFeed(RssFeed feed, String feedUrl) {
    final feedSource = allFeedSources.firstWhere(
      (s) => s.url == feedUrl,
      orElse: () => FeedSource(name: 'Unknown', url: feedUrl, category: ''),
    );

    return feed.items?.map((item) {
          String? imageUrl =
              item.media?.contents?.firstOrNull?.url ??
              item.media?.thumbnails?.firstOrNull?.url ??
              (item.enclosure?.type?.startsWith('image') == true
                  ? item.enclosure!.url
                  : null) ??
              item.content?.images?.firstOrNull ??
              _extractImageFromHtml(item.description ?? '') ??
              _extractImageFromHtml(item.content?.value ?? '');

          // Clean and normalize all text fields
          final author = (item.author ?? item.dc?.creator ?? feedSource.name)
              .trim()
              .replaceAll(RegExp(r'\s+'), ' ')
              .replaceAll(RegExp(r'[\n\r\t]'), ' ');

          return FeedItem(
            id:
                (item.guid ??
                        item.link ??
                        '${feedUrl}_${DateTime.now().millisecondsSinceEpoch}')
                    .trim(),
            feedSource: feedSource.name.trim(),
            feedSourceImage: (feed.image?.url ?? '').trim(),
            title: (item.title ?? 'Untitled').trim().replaceAll(
              RegExp(r'\s+'),
              ' ',
            ),
            description: _stripHtmlTags(item.description ?? ''),
            author: author,
            date: _parseDateTime(item.pubDate),
            link: (item.link ?? '').trim(),
            image: imageUrl?.trim(),
          );
        }).toList() ??
        [];
  }

  List<FeedItem> parseAtomFeed(AtomFeed feed, String feedUrl) {
    final feedSource = allFeedSources.firstWhere(
      (s) => s.url == feedUrl,
      orElse: () => FeedSource(name: 'Unknown', url: feedUrl, category: ''),
    );

    return feed.items?.map((item) {
          final imageLinks = item.links?.where(
            (l) => l.rel == 'enclosure' && l.type?.startsWith('image') == true,
          );

          String? imageUrl =
              imageLinks?.firstOrNull?.href ??
              _extractImageFromHtml(item.summary ?? '') ??
              _extractImageFromHtml(item.content ?? '');

          DateTime itemDate = DateTime.now();
          try {
            if (item.published is String) {
              itemDate = DateTime.parse(item.published as String);
            } else if (item.published is DateTime) {
              itemDate = item.published as DateTime;
            } else if (item.updated is String) {
              itemDate = DateTime.parse(item.updated as String);
            } else if (item.updated is DateTime) {
              itemDate = item.updated as DateTime;
            }
            itemDate = _parseDateTime(itemDate);
          } catch (e) {
            itemDate = DateTime.now();
          }

          // Clean and normalize all text fields
          final author = (item.authors?.firstOrNull?.name ?? feedSource.name)
              .trim()
              .replaceAll(RegExp(r'\s+'), ' ')
              .replaceAll(RegExp(r'[\n\r\t]'), ' ');

          return FeedItem(
            id:
                (item.id ??
                        '${feedUrl}_${DateTime.now().millisecondsSinceEpoch}')
                    .trim(),
            feedSource: feedSource.name.trim(),
            feedSourceImage: (feed.icon ?? feed.logo ?? '').trim(),
            title: (item.title ?? 'Untitled').trim().replaceAll(
              RegExp(r'\s+'),
              ' ',
            ),
            description: _stripHtmlTags(item.summary ?? item.content ?? ''),
            author: author,
            date: itemDate,
            link: (item.links?.firstOrNull?.href ?? '').trim(),
            image: imageUrl?.trim(),
          );
        }).toList() ??
        [];
  }

  String _stripHtmlTags(String html) {
    if (html.isEmpty) return '';
    // Remove HTML tags, decode entities, normalize whitespace
    return html
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String? _extractImageFromHtml(String html) {
    if (html.isEmpty) return null;

    final patterns = [
      RegExp(r'<img[^>]+src="([^">]+)"', caseSensitive: false),
      RegExp(r"<img[^>]+src='([^'>]+)'", caseSensitive: false),
      RegExp(
        r'<meta[^>]+property="og:image"[^>]+content="([^">]+)"',
        caseSensitive: false,
      ),
    ];

    for (var pattern in patterns) {
      final match = pattern.firstMatch(html);
      if (match != null && match.group(1) != null) {
        final imageUrl = match.group(1)!.replaceAll('&amp;', '&').trim();
        if (imageUrl.startsWith('http') && _isValidImageUrl(imageUrl)) {
          return imageUrl;
        }
      }
    }
    return null;
  }

  bool _isValidImageUrl(String url) {
    try {
      final uri = Uri.parse(url);
      final path = uri.path.toLowerCase();
      // Check for common image extensions
      return path.endsWith('.jpg') ||
          path.endsWith('.jpeg') ||
          path.endsWith('.png') ||
          path.endsWith('.gif') ||
          path.endsWith('.webp') ||
          url.contains('image');
    } catch (e) {
      return false;
    }
  }

  String formatDate(DateTime date) {
    final now = DateTime.now();
    final difference = now.difference(date);

    if (difference.inSeconds < 60) return 'Just now';
    if (difference.inMinutes < 60) return '${difference.inMinutes}m';
    if (difference.inHours < 24) return '${difference.inHours}h';
    if (difference.inDays < 7) return '${difference.inDays}d';
    return DateFormat('MMM d').format(date);
  }

  // UI Actions
  void toggleSource(String url) {
    setState(() {
      if (selectedSourceUrls.contains(url)) {
        selectedSourceUrls.remove(url);
      } else {
        selectedSourceUrls.add(url);
      }
    });
    saveSelectedSources();
    loadFeedsProgressively();
  }

  void _showSnackBar(String message) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  void showAddCustomFeedDialog() {
    final nameController = TextEditingController();
    final urlController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('Add Custom Feed'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'Feed Name',
                hintText: 'e.g., My Blog',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: urlController,
              decoration: const InputDecoration(
                labelText: 'Feed URL',
                hintText: 'https://example.com/feed.xml',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              if (urlController.text.trim().isEmpty) {
                _showSnackBar('Please enter a feed URL');
                return;
              }
              Navigator.pop(context);
              addCustomSource(
                nameController.text.trim(),
                urlController.text.trim(),
              );
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  void openWebView(String url, String title, String feedSource) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            WebViewPage(url: url, title: title, feedSource: feedSource),
      ),
    );
  }

  void openImageViewer(String imageUrl) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ImageViewerPage(imageUrl: imageUrl),
      ),
    );
  }

  void shareItem(FeedItem item) {
    Share.share('${item.title}\n\n${item.link}', subject: item.title);
  }

  // Filtering
  List<FeedItem> get filteredFeedItems {
    var filtered = _feedItems;

    if (selectedCategory != null) {
      final categoryFeeds = allFeedSources
          .where((s) => s.category == selectedCategory)
          .map((s) => s.name)
          .toSet();
      filtered = filtered
          .where((item) => categoryFeeds.contains(item.feedSource))
          .toList();
    }

    if (selectedFeedSource != null) {
      filtered = filtered
          .where((item) => item.feedSource == selectedFeedSource)
          .toList();
    }

    return filtered;
  }

  Set<String> get availableCategories {
    return allFeedSources
        .where((source) => selectedSourceUrls.contains(source.url))
        .map((source) => source.category)
        .toSet();
  }

  void clearFilters() {
    setState(() {
      selectedCategory = null;
      selectedFeedSource = null;
    });
  }

  void filterByFeedSource(String feedSource) {
    setState(() {
      selectedFeedSource = feedSource;
      selectedCategory = null;
    });
    if (_homeScrollController.hasClients) {
      _homeScrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  // UI Builders
  Widget _buildHomePage() {
    final displayItems = filteredFeedItems;

    if (_feedItems.isEmpty && isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFFFF9500)),
      );
    }

    if (_feedItems.isEmpty && isRefreshing) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(color: Color(0xFFFF9500)),
            const SizedBox(height: 16),
            Text(
              'Loading feeds... ($_loadedFeedsCount/$_totalFeedsToLoad)',
              style: const TextStyle(color: Color(0xFF666666)),
            ),
          ],
        ),
      );
    }

    if (_feedItems.isEmpty && !isRefreshing && !isLoading) {
      return const Center(
        child: Text(
          'No feeds selected.\nGo to Sources tab to choose feeds.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Color(0xFF666666)),
        ),
      );
    }

    return Column(
      children: [
        if (availableCategories.isNotEmpty)
          _buildFilterChips(displayItems.length),
        if (selectedFeedSource != null) _buildActiveFilterBar(),
        if (isRefreshing && _feedItems.isNotEmpty) _buildLoadingBar(),
        Expanded(
          child: displayItems.isEmpty && _feedItems.isNotEmpty
              ? const Center(
                  child: Text(
                    'No feeds in this filter',
                    style: TextStyle(color: Color(0xFF666666)),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: loadFeedsProgressively,
                  color: const Color(0xFFFF9500),
                  child: ListView.separated(
                    controller: _homeScrollController,
                    itemCount: displayItems.length,
                    physics: const AlwaysScrollableScrollPhysics(),
                    separatorBuilder: (context, index) => const Divider(
                      height: 1,
                      thickness: 0.3,
                      color: Color(0xFF2A2A2A),
                    ),
                    itemBuilder: (context, index) {
                      final item = displayItems[index];
                      return FeedItemWidget(
                        key: ValueKey(item.id),
                        item: item,
                        formatDate: formatDate,
                        isSaved: isItemSaved(item.id),
                        onSave: () => saveFeedItem(item),
                        onOpen: () =>
                            openWebView(item.link, item.title, item.feedSource),
                        onShare: () => shareItem(item),
                        onImageTap: item.image != null
                            ? () => openImageViewer(item.image!)
                            : null,
                        onFeedSourceTap: () =>
                            filterByFeedSource(item.feedSource),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildFilterChips(int totalCount) {
    return Container(
      height: 52,
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Color(0xFF2A2A2A), width: 0.3),
        ),
      ),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        children: [
          _buildChip(
            'All',
            totalCount,
            selectedCategory == null && selectedFeedSource == null,
            () => clearFilters(),
          ),
          ...availableCategories.map((category) {
            final count = _feedItems.where((item) {
              final categoryFeeds = allFeedSources
                  .where(
                    (s) =>
                        s.category == category &&
                        selectedSourceUrls.contains(s.url),
                  )
                  .map((s) => s.name)
                  .toSet();
              return categoryFeeds.contains(item.feedSource);
            }).length;

            return _buildChip(
              category == 'custom'
                  ? 'Custom'
                  : category[0].toUpperCase() + category.substring(1),
              count,
              selectedCategory == category,
              () {
                setState(() {
                  selectedCategory = selectedCategory == category
                      ? null
                      : category;
                  selectedFeedSource = null;
                });
              },
            );
          }),
        ],
      ),
    );
  }

  Widget _buildChip(
    String label,
    int count,
    bool isSelected,
    VoidCallback onTap,
  ) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(
            color: isSelected ? const Color(0xFFFF9500) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isSelected
                  ? const Color(0xFFFF9500)
                  : const Color(0xFF2A2A2A),
              width: 1,
            ),
          ),
          child: Center(
            child: Text(
              '$label ($count)',
              style: TextStyle(
                color: isSelected ? Colors.black : Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                height: 1.2,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildActiveFilterBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Color(0xFF2A2A2A), width: 0.3),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.filter_alt, size: 16, color: Color(0xFF666666)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Showing: $selectedFeedSource',
              style: const TextStyle(color: Color(0xFF666666), fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          GestureDetector(
            onTap: clearFilters,
            child: const Text(
              'Clear',
              style: TextStyle(color: Color(0xFFFF9500), fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingBar() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Color(0xFF2A2A2A), width: 0.3),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Color(0xFFFF9500),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            'Loading... ($_loadedFeedsCount/$_totalFeedsToLoad)',
            style: const TextStyle(color: Color(0xFF666666), fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildSavedPage() {
    if (savedItems.isEmpty) {
      return const Center(
        child: Text(
          'No saved items yet.\nTap the heart icon to save posts.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Color(0xFF666666)),
        ),
      );
    }

    return ListView.separated(
      controller: _savedScrollController,
      itemCount: savedItems.length,
      physics: const AlwaysScrollableScrollPhysics(),
      separatorBuilder: (context, index) =>
          const Divider(height: 1, thickness: 0.3, color: Color(0xFF2A2A2A)),
      itemBuilder: (context, index) {
        final item = savedItems[index];
        return FeedItemWidget(
          key: ValueKey(item.id),
          item: item,
          formatDate: formatDate,
          isSaved: true,
          onSave: () => saveFeedItem(item),
          onOpen: () => openWebView(item.link, item.title, item.feedSource),
          onShare: () => shareItem(item),
          onImageTap: item.image != null
              ? () => openImageViewer(item.image!)
              : null,
          onFeedSourceTap: null,
        );
      },
    );
  }

  Widget _buildSourcesPage() {
    final categorizedFeeds = <String, List<FeedSource>>{};
    for (var source in allFeedSources) {
      categorizedFeeds.putIfAbsent(source.category, () => []).add(source);
    }

    final sortedCategories = categorizedFeeds.keys.toList()
      ..sort(
        (a, b) => a == 'custom'
            ? -1
            : b == 'custom'
            ? 1
            : a.compareTo(b),
      );

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: showAddCustomFeedDialog,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text(
                'Add Custom Feed',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ),
        const Divider(height: 1, thickness: 0.3, color: Color(0xFF2A2A2A)),
        Expanded(
          child: ListView.builder(
            itemCount: sortedCategories.length,
            itemBuilder: (context, catIndex) {
              final categoryKey = sortedCategories[catIndex];
              final sources = categorizedFeeds[categoryKey]!;
              final isExpanded = expandedCategories.contains(categoryKey);
              final selectedCount = sources
                  .where((s) => selectedSourceUrls.contains(s.url))
                  .length;

              return Column(
                children: [
                  ListTile(
                    title: Row(
                      children: [
                        Text(
                          categoryKey == 'custom'
                              ? 'CUSTOM'
                              : categoryKey.toUpperCase(),
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.5,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF2A2A2A),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '$selectedCount/${sources.length}',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFF666666),
                            ),
                          ),
                        ),
                      ],
                    ),
                    trailing: Icon(
                      isExpanded ? Icons.expand_less : Icons.expand_more,
                      size: 20,
                    ),
                    onTap: () {
                      setState(() {
                        if (isExpanded) {
                          expandedCategories.remove(categoryKey);
                        } else {
                          expandedCategories.add(categoryKey);
                        }
                      });
                    },
                  ),
                  if (isExpanded)
                    ...sources.map((source) {
                      final isSelected = selectedSourceUrls.contains(
                        source.url,
                      );
                      final isCustom = source.category == 'custom';

                      return ListTile(
                        contentPadding: const EdgeInsets.only(
                          left: 32,
                          right: 16,
                        ),
                        title: Text(
                          source.name,
                          style: const TextStyle(fontSize: 14),
                        ),
                        subtitle: Text(
                          source.url,
                          style: const TextStyle(
                            color: Color(0xFF666666),
                            fontSize: 11,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Switch(
                              value: isSelected,
                              onChanged: (value) => toggleSource(source.url),
                              activeColor: const Color(0xFFFF9500),
                            ),
                            if (isCustom)
                              IconButton(
                                icon: const Icon(
                                  Icons.delete_outline,
                                  color: Colors.red,
                                  size: 20,
                                ),
                                onPressed: () => _showDeleteDialog(source),
                              ),
                          ],
                        ),
                        onTap: () => toggleSource(source.url),
                      );
                    }),
                  const Divider(
                    height: 1,
                    thickness: 0.3,
                    color: Color(0xFF2A2A2A),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  void _showDeleteDialog(FeedSource source) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('Delete Custom Feed'),
        content: Text('Delete "${source.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              deleteCustomSource(source.url);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _currentIndex == 0
              ? 'Reeds'
              : _currentIndex == 1
              ? 'Saved'
              : 'Sources',
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 28,
            color: Color(0xFFFF9500),
          ),
        ),
        actions: _currentIndex == 0
            ? [
                IconButton(
                  icon: const Icon(Icons.refresh, size: 24),
                  onPressed: isRefreshing ? null : loadFeedsProgressively,
                ),
              ]
            : null,
      ),
      body: IndexedStack(
        index: _currentIndex,
        children: [_buildHomePage(), _buildSavedPage(), _buildSourcesPage()],
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: Color(0xFF2A2A2A), width: 0.3)),
        ),
        child: BottomNavigationBar(
          currentIndex: _currentIndex,
          onTap: (index) {
            if (index == _currentIndex && (index == 0 || index == 1)) {
              final controller = index == 0
                  ? _homeScrollController
                  : _savedScrollController;
              if (controller.hasClients) {
                controller.animateTo(
                  0,
                  duration: const Duration(milliseconds: 500),
                  curve: Curves.easeOutCubic,
                );
              }
            } else {
              setState(() => _currentIndex = index);
            }
          },
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.home_outlined),
              activeIcon: Icon(Icons.home),
              label: 'Home',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.favorite_outline),
              activeIcon: Icon(Icons.favorite),
              label: 'Saved',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.rss_feed_outlined),
              activeIcon: Icon(Icons.rss_feed),
              label: 'Sources',
            ),
          ],
        ),
      ),
    );
  }
}

// Feed Item Widget - Threads-inspired design
class FeedItemWidget extends StatefulWidget {
  final FeedItem item;
  final String Function(DateTime) formatDate;
  final bool isSaved;
  final VoidCallback onSave;
  final VoidCallback onOpen;
  final VoidCallback onShare;
  final VoidCallback? onImageTap;
  final VoidCallback? onFeedSourceTap;

  const FeedItemWidget({
    super.key,
    required this.item,
    required this.formatDate,
    required this.isSaved,
    required this.onSave,
    required this.onOpen,
    required this.onShare,
    this.onImageTap,
    this.onFeedSourceTap,
  });

  @override
  State<FeedItemWidget> createState() => _FeedItemWidgetState();
}

class _FeedItemWidgetState extends State<FeedItemWidget> {
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              GestureDetector(
                onTap: widget.onFeedSourceTap,
                child: CircleAvatar(
                  radius: 18,
                  backgroundColor: const Color(0xFF2A2A2A),
                  child: widget.item.feedSourceImage.isNotEmpty
                      ? ClipOval(
                          child: CachedNetworkImage(
                            imageUrl: widget.item.feedSourceImage,
                            width: 36,
                            height: 36,
                            fit: BoxFit.cover,
                            placeholder: (_, __) => _buildAvatarFallback(),
                            errorWidget: (_, __, ___) => _buildAvatarFallback(),
                            fadeInDuration: const Duration(milliseconds: 150),
                            memCacheWidth: 72,
                            memCacheHeight: 72,
                            maxHeightDiskCache: 72,
                            maxWidthDiskCache: 72,
                          ),
                        )
                      : _buildAvatarFallback(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: GestureDetector(
                  onTap: widget.onFeedSourceTap,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.item.feedSource,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              widget.item.author,
                              style: const TextStyle(
                                color: Color(0xFF666666),
                                fontSize: 13,
                              ),
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                            ),
                          ),
                          Text(
                            ' · ${widget.formatDate(widget.item.date)}',
                            style: const TextStyle(
                              color: Color(0xFF666666),
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Content
          GestureDetector(
            onTap: widget.onOpen,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.item.title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    height: 1.4,
                  ),
                ),
                if (widget.item.description.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    widget.item.description,
                    style: const TextStyle(
                      color: Color(0xFFCCCCCC),
                      fontSize: 15,
                      height: 1.5,
                    ),
                    maxLines: _isExpanded ? null : 3,
                    overflow: _isExpanded
                        ? TextOverflow.visible
                        : TextOverflow.ellipsis,
                  ),
                  if (widget.item.description.length > 150)
                    GestureDetector(
                      onTap: () => setState(() => _isExpanded = !_isExpanded),
                      child: Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          _isExpanded ? 'Show less' : 'Read more',
                          style: const TextStyle(
                            color: Color(0xFF666666),
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),

          // Image
          if (widget.item.image != null && widget.item.image!.isNotEmpty) ...[
            const SizedBox(height: 12),
            GestureDetector(
              onTap: widget.onImageTap,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: CachedNetworkImage(
                  imageUrl: widget.item.image!,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  placeholder: (_, __) => Container(
                    height: 200,
                    color: const Color(0xFF2A2A2A),
                    child: const Center(
                      child: CircularProgressIndicator(
                        color: Color(0xFF666666),
                        strokeWidth: 2,
                      ),
                    ),
                  ),
                  errorWidget: (_, __, ___) => const SizedBox.shrink(),
                  fadeInDuration: const Duration(milliseconds: 200),
                  maxHeightDiskCache: 600,
                  maxWidthDiskCache: 600,
                ),
              ),
            ),
          ],

          const SizedBox(height: 16),

          // Action Buttons - Segmented style
          Container(
            height: 42,
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFF2A2A2A), width: 1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Expanded(
                  child: _ActionButton(
                    icon: widget.isSaved
                        ? Icons.favorite
                        : Icons.favorite_outline,
                    color: widget.isSaved
                        ? Colors.red
                        : const Color(0xFF666666),
                    onTap: widget.onSave,
                  ),
                ),
                Container(width: 1, height: 24, color: const Color(0xFF2A2A2A)),
                Expanded(
                  child: _ActionButton(
                    icon: Icons.open_in_browser,
                    color: const Color(0xFF666666),
                    onTap: widget.onOpen,
                  ),
                ),
                Container(width: 1, height: 24, color: const Color(0xFF2A2A2A)),
                Expanded(
                  child: _ActionButton(
                    icon: Icons.share_outlined,
                    color: const Color(0xFF666666),
                    onTap: widget.onShare,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAvatarFallback() {
    return Container(
      width: 36,
      height: 36,
      color: const Color(0xFF666666),
      child: Center(
        child: Text(
          widget.item.feedSource.isNotEmpty
              ? widget.item.feedSource[0].toUpperCase()
              : '?',
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 16,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Center(child: Icon(icon, size: 20, color: color)),
    );
  }
}

// WebView Page
class WebViewPage extends StatefulWidget {
  final String url;
  final String title;
  final String feedSource;

  const WebViewPage({
    super.key,
    required this.url,
    required this.title,
    required this.feedSource,
  });

  @override
  State<WebViewPage> createState() => _WebViewPageState();
}

class _WebViewPageState extends State<WebViewPage> {
  double _progress = 0;
  InAppWebViewController? _webViewController;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.feedSource,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            Text(
              widget.title,
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFF666666),
                fontWeight: FontWeight.normal,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.open_in_browser),
            onPressed: () async {
              if (_webViewController != null) {
                final url = await _webViewController!.getUrl();
                if (url != null) {
                  final uri = Uri.parse(url.toString());
                  if (await canLaunchUrl(uri)) {
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  } else if (mounted) {
                    Share.share(uri.toString());
                  }
                }
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: () => Share.share('${widget.title}\n\n${widget.url}'),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_progress < 1.0)
            LinearProgressIndicator(
              value: _progress,
              backgroundColor: const Color(0xFF2A2A2A),
              valueColor: const AlwaysStoppedAnimation<Color>(
                Color(0xFFFF9500),
              ),
            ),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(widget.url)),
              initialSettings: InAppWebViewSettings(
                mediaPlaybackRequiresUserGesture: false,
                allowsInlineMediaPlayback: true,
                javaScriptEnabled: true,
                domStorageEnabled: true,
                databaseEnabled: true,
                cacheEnabled: true,
                clearCache: false,
              ),
              onWebViewCreated: (controller) => _webViewController = controller,
              onProgressChanged: (controller, progress) {
                setState(() => _progress = progress / 100);
              },
              // Suppress console messages
              onConsoleMessage: (controller, consoleMessage) {
                // Silently ignore console messages
              },
              // Suppress load resource logging
              onLoadResource: (controller, resource) {
                // Silently ignore resource loading
              },
            ),
          ),
        ],
      ),
    );
  }
}

// Image Viewer Page
class ImageViewerPage extends StatelessWidget {
  final String imageUrl;

  const ImageViewerPage({super.key, required this.imageUrl});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: () => Share.share(imageUrl),
          ),
        ],
      ),
      body: PhotoView(
        imageProvider: CachedNetworkImageProvider(imageUrl),
        minScale: PhotoViewComputedScale.contained,
        maxScale: PhotoViewComputedScale.covered * 3,
        initialScale: PhotoViewComputedScale.contained,
        backgroundDecoration: const BoxDecoration(color: Colors.black),
        loadingBuilder: (context, event) => Center(
          child: CircularProgressIndicator(
            value: event == null
                ? 0
                : event.cumulativeBytesLoaded / (event.expectedTotalBytes ?? 1),
            color: const Color(0xFFFF9500),
          ),
        ),
        errorBuilder: (_, __, ___) => const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 48, color: Color(0xFF666666)),
              SizedBox(height: 16),
              Text(
                'Failed to load image',
                style: TextStyle(color: Color(0xFF666666)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

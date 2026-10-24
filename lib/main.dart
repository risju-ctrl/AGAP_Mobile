import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Deployed backend (Render): gumagana sa emulator at sa totoong phone, walang IP/adb na kailangan.
// Para sa local server sa laptop (emulator lang): 'http://10.0.2.2:5000/api'
const String kApiBase = 'https://web-road-accident-tracker.onrender.com/api';
// Mapbox public token (yung "pk." galing sa client/.env ng web, VITE_MAPBOX_TOKEN).
// Ilagay dito, o i-run gamit ang: flutter run --dart-define=MAPBOX_TOKEN=pk.xxxxx
   const String kMapboxToken = String.fromEnvironment(
     'MAPBOX_TOKEN',
     defaultValue: '',
   ); 
const String kPackageName = 'com.agap.reporter'; // para sa OpenStreetMap (palitan kung iba ang package name mo)

// Parehong Mapbox map ng web: dark-v11 (night) sa dark mode, streets-v12 sa light.
// Kung walang token, OpenStreetMap ang gagamitin para hindi masira ang app.
Widget appTileLayer() {
  if (!kMapboxToken.startsWith('pk.')) {
    return TileLayer(
      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      userAgentPackageName: kPackageName,
    );
  }
  final style = darkMode.value ? 'dark-v11' : 'streets-v12';
  return TileLayer(
    urlTemplate:
        'https://api.mapbox.com/styles/v1/mapbox/$style/tiles/256/{z}/{x}/{y}@2x?access_token=$kMapboxToken',
    userAgentPackageName: kPackageName,
  );
}

final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();

class ApiException implements Exception {
  final int status;
  final String code, message;
  final Map<String, dynamic>? raw;
  ApiException(this.status, this.code, this.message, [this.raw]);
  @override
  String toString() => message;
}

// app -> web values
const kTypeToCategory = {
  'Crash': 'Vehicle Collision',
  'Hit and run': 'Hit and Run',
  'Flipped over': 'Vehicle Rollover',
  'Person hit': 'Pedestrian Accident',
  'Other': 'Other',
};
const kInjuryToApi = {
  'None': 'none', 'Injuries': 'injuries', 'Fatalities': 'fatalities', 'Unknown': 'unknown',
};
const kInjuryLabel = {
  'none': 'None', 'injuries': 'Injuries', 'fatalities': 'Fatalities', 'unknown': 'Unknown',
};
const kSeverityToApi = {'Minor': 'minor', 'Moderate': 'moderate', 'Major': 'major', 'Fatal': 'fatal'};
const kSeverityLabel = {'minor': 'Minor', 'moderate': 'Moderate', 'major': 'Major', 'fatal': 'Fatal'};
// lahat ng 8 statuses ng web (may 8 din sa requirements ni sir)
const kStatusLabel = {
  'submitted': 'Sent', 'under_review': 'Reviewing', 'needs_clarification': 'Needs info',
  'verified': 'Verified', 'assigned': 'Assigned', 'in_progress': 'In progress',
  'resolved': 'Resolved', 'rejected': 'Rejected',
};

class Api {
  static String? token;
  static List<dynamic>? _cats;

  static Future<dynamic> call(String method, String path, {Object? body}) async {
    http.Response res;
    try {
      final req = http.Request(method, Uri.parse('$kApiBase$path'))
        ..headers['Content-Type'] = 'application/json';
      if (token != null) req.headers['Authorization'] = 'Bearer $token';
      if (body != null) req.body = jsonEncode(body);
      res = await http.Response.fromStream(
          await req.send().timeout(const Duration(seconds: 60))); // 60s: ang libreng Render ay natutulog kapag walang gumagamit
    } catch (_) {
      throw ApiException(0, 'NETWORK', 'Cannot reach the server. Check your connection.');
    }
    dynamic data;
    try { data = res.body.isEmpty ? null : jsonDecode(res.body); } catch (_) {}
    if (res.statusCode >= 200 && res.statusCode < 300) return data;
    // Nag-expire na ang login (o hindi na valid): ibalik sa Login screen
    if (res.statusCode == 401 && token != null) await expireSession();
    final e = data is Map ? data['error'] : null;
    throw ApiException(res.statusCode, '${e?['code'] ?? 'ERROR'}',
        '${e?['message'] ?? 'Something went wrong'}',
        e is Map ? Map<String, dynamic>.from(e) : null);
  }

  static Future<void> register(String name, String phone, String email, String password) =>
      call('POST', '/auth/register',
          body: {'name': name, 'phone': phone, 'email': email, 'password': password});

  static Future<void> login(String email, String password) async {
    final r = await call('POST', '/auth/login', body: {'email': email, 'password': password});
    final u = Map<String, dynamic>.from(r['user']);
    // admin/officer ay sa web; kung hindi ito, makikita nila ang LAHAT ng reports
    if (u['role'] != 'reporter') {
      throw ApiException(403, 'FORBIDDEN', 'This app is for reporters. Staff, please use the web portal.');
    }
    token = r['token'];
    user.value = UserProfile('${u['name']}', '${u['phone'] ?? ''}', '${u['email']}');
    await saveSession();
  }

  // Naka-save sa phone para hindi ma-log out kapag isinara ang app
  static Future<void> saveSession() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('token', token ?? '');
      await p.setString('u_name', user.value.name);
      await p.setString('u_phone', user.value.mobile);
      await p.setString('u_email', user.value.email);
    } catch (_) {}
  }

  static Future<void> clearSaved() async {
    try {
      final p = await SharedPreferences.getInstance();
      for (final k in ['token', 'u_name', 'u_phone', 'u_email']) {
        await p.remove(k);
      }
    } catch (_) {}
  }

  // True kung may nakitang saved login
  static Future<bool> restoreSession() async {
    try {
      final p = await SharedPreferences.getInstance();
      final t = p.getString('token') ?? '';
      if (t.isEmpty) return false;
      token = t;
      user.value = UserProfile(p.getString('u_name') ?? '', p.getString('u_phone') ?? '',
          p.getString('u_email') ?? '');
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> expireSession() async {
    token = null;
    await clearSaved();
    user.value = const UserProfile('', '', '');
    reports.value = [];
    alerts.value = [];
    reportsLoaded.value = false;
    navKey.currentState?.pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()), (_) => false);
  }

  static Future<void> logout() async {
    try { await call('POST', '/auth/logout'); } catch (_) {}
    token = null;
    await clearSaved();
    user.value = const UserProfile('', '', '');
    reports.value = []; // para hindi lumipat ang reports sa susunod na account
    alerts.value = [];
    reportsLoaded.value = false;
  }

  static Future<List<Report>> myReports() async {
    final list = (await call('GET', '/reports')) as List;
    return [for (final j in list) Report.fromJson(Map<String, dynamic>.from(j))];
  }

  static Future<List<AlertItem>> myAlerts() async {
    final r = await call('GET', '/notifications?limit=50');
    return [for (final n in (r['rows'] as List)) AlertItem.fromJson(Map<String, dynamic>.from(n))];
  }

  static Future<void> markRead(int id) => call('POST', '/notifications/$id/read');
  static Future<void> markAllRead() => call('POST', '/notifications/read-all');

  // Parehong paraan ng server: ang uri ng file ay kinukuha sa mismong bytes
  static String? sniffMime(Uint8List b) {
    if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return 'image/jpeg';
    if (b.length >= 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) return 'image/png';
    if (b.length >= 12 && b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
        b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
      return 'image/webp';
    }
    return null;
  }

  static Map<String, String> get authHeaders =>
      token == null ? {} : {'Authorization': 'Bearer $token'};

  static String evidenceUrl(int reportId, int evidenceId) =>
      '$kApiBase/reports/$reportId/evidence/$evidenceId';

  // POST /reports/:id/evidence  (isang file bawat request, field name: "file")
  static Future<void> uploadEvidence(int reportId, Photo p) async {
    final mime = sniffMime(p.bytes);
    if (mime == null) throw ApiException(0, 'BAD_FILE', 'Only JPG, PNG or WebP photos are allowed.');
    final req = http.MultipartRequest('POST', Uri.parse('$kApiBase/reports/$reportId/evidence'))
      ..headers.addAll(authHeaders)
      ..files.add(http.MultipartFile.fromBytes('file', p.bytes,
          filename: p.name.isEmpty ? 'photo.jpg' : p.name, contentType: MediaType.parse(mime)));
    http.Response res;
    try {
      res = await http.Response.fromStream(await req.send().timeout(const Duration(seconds: 60)));
    } catch (_) {
      throw ApiException(0, 'NETWORK', 'Cannot reach the server. Check your connection.');
    }
    if (res.statusCode >= 200 && res.statusCode < 300) return;
    String msg = 'Photo upload failed';
    try {
      final e = (jsonDecode(res.body) as Map)['error'];
      if (e is Map && e['message'] != null) msg = '${e['message']}';
    } catch (_) {}
    throw ApiException(res.statusCode, 'UPLOAD', msg);
  }

  static Future<List<Map<String, dynamic>>> reportEvidence(int reportId) async {
    final r = await call('GET', '/reports/$reportId');
    final list = (r is Map ? r['evidence'] : null) as List? ?? const [];
    return [for (final e in list) Map<String, dynamic>.from(e as Map)];
  }

  // Buong detalye ng isang report mula sa server: kasama ang evidence at status_history
  static Future<Map<String, dynamic>> reportFull(int reportId) async {
    final r = await call('GET', '/reports/$reportId');
    return Map<String, dynamic>.from(r as Map);
  }

  static Future<List<Map<String, dynamic>>> categories() async {
    _cats ??= (await call('GET', '/accident-categories')) as List;
    return [for (final c in _cats!) Map<String, dynamic>.from(c as Map)];
  }

  // PATCH /reports/:id (ganito rin ang web). Kapag "Needs info" ang report, ibinabalik ito
  // ng server sa Under review kapag na-save.
  static Future<void> updateReport(int id, Map<String, dynamic> body) =>
      call('PATCH', '/reports/$id', body: body);

  static Future<Map<String, dynamic>> createReport(Draft d,{Map<String, dynamic> answer = const {}}) async {
    _cats ??= (await call('GET', '/accident-categories')) as List;
    final want = kTypeToCategory[d.type] ?? 'Other';
    final cat = _cats!.cast<Map>().firstWhere((c) => c['name'] == want,
        orElse: () => throw ApiException(0, 'NO_CATEGORY', 'Accident type "$want" is missing in the database.'));
    final place = d.place.trim();
    final r = await call('POST', '/reports', body: {
      'title': d.title.trim(),
      'description': d.description.trim(),
      'accident_date': d.date,
      'accident_time': d.time,
      'location': place,
      if (d.lat != null && d.lng != null) ...{
        'latitude': double.parse(d.lat!.toStringAsFixed(6)),
        'longitude': double.parse(d.lng!.toStringAsFixed(6)),
      },
      'accident_category_id': cat['id'],
      'injury_status': kInjuryToApi[d.injury] ?? 'unknown',
      if (d.severity != null) 'severity': kSeverityToApi[d.severity],
      if (d.injury == 'None') ...{'injuries': 0, 'fatalities': 0},
      if (d.injury == 'Injuries' || d.injury == 'Fatalities')
        ...{'injuries': d.injuries, 'fatalities': d.fatalities},
      if (d.noVehicles || d.vehicles.isNotEmpty)
        'vehicle_type': d.noVehicles ? 'None' : d.vehicles.join(', '),
      if (d.noVehicles || d.vehicles.isNotEmpty)
        'vehicles_involved': d.noVehicles ? 0 : d.total,
      ...answer,
    });
    return Map<String, dynamic>.from(r);
  }
}

// false hanggang sa unang matagumpay na load ng reports (para sa "Loading..." ng Dashboard)
final ValueNotifier<bool> reportsLoaded = ValueNotifier<bool>(false);

Future<void> refreshAll() async {
  reports.value = await Api.myReports(); // una ang reports, kailangan ng alerts para sa kulay
  reportsLoaded.value = true;
  alerts.value = await Api.myAlerts();
}

String todayIso() {
  final n = DateTime.now();
  return '${n.year}-${two(n.month)}-${two(n.day)}';
}

bool _sending = false;
Future<void> submitDraft(BuildContext context, {Map<String, dynamic> answer = const {}}) async {
  if (_sending) return;
  _sending = true;
  final nav = Navigator.of(context);
  final msg = ScaffoldMessenger.of(context);
  Map<String, dynamic>? retry;
  try {
    final created = await Api.createReport(draft, answer: answer);
    // Gawa muna ang report, saka isa-isang i-upload ang mga larawan (ganito rin ang web)
    var failed = 0;
    final reportId = created['id'];
    if (reportId is int) {
      for (final p in List<Photo>.of(draft.photos)) {
        try {
          await Api.uploadEvidence(reportId, p);
        } catch (_) {
          failed++;
        }
      }
    } else {
      failed = draft.photos.length;
    }
    draft.photos.clear();
    await refreshAll();
    nav.pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => SentScreen('${created['report_reference']}')),
        (r) => r.isFirst);
    if (failed > 0) {
      msg.showSnackBar(SnackBar(
          content: Text('Report sent, but $failed photo(s) could not be uploaded.')));
    }
  } on ApiException catch (e) {
    if (e.code == 'POSSIBLE_DUPLICATE' && context.mounted) {
      final dup = ((e.raw?['duplicates'] as List?)?.first) as Map?;
      final same = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: C.surface,
          title: const Text('Already reported?'),
          content: Text('This looks like ${dup?['report_reference'] ?? 'a report'} at '
              '${dup?['location'] ?? 'the same place'}. Is it the same accident?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No, different')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Yes, same')),
          ],
        ),
      );
      if (same != null) {
        retry = same ? {'duplicate_of': dup?['id']} : {'confirm_distinct': true};
      }
    } else {
      msg.showSnackBar(SnackBar(content: Text(e.message)));
    }
  } finally {
    _sending = false;
  }
  if (retry != null && context.mounted) await submitDraft(context, answer: retry);
}

final ValueNotifier<bool> darkMode = ValueNotifier<bool>(true);

void _rebuildAll() {
  void visit(Element e) {
    e.markNeedsBuild();
    e.visitChildren(visit);
  }
  WidgetsBinding.instance.rootElement?.visitChildren(visit);
}

void setDark(bool v) {
  darkMode.value = v;
  _rebuildAll();
}

class C {
  static bool get d => darkMode.value;
  static Color get bg => d ? const Color(0xFF171718) : const Color(0xFFF6F2E9);
  static Color get surface => d ? const Color(0xFF211E1A) : const Color(0xFFFFFFFF);
  static Color get surface2 => d ? const Color(0xFF2B2722) : const Color(0xFFEFE9DB);
  static Color get border => d ? const Color(0xFF3A352E) : const Color(0xFFDDD5C3);
  static Color get cream => d ? const Color(0xFFEFE2B0) : const Color(0xFF8F6B1A);
  static Color get text => d ? const Color(0xFFF3EEE3) : const Color(0xFF1B1A18);
  static Color get muted => d ? const Color(0xFF9A9284) : const Color(0xFF6F685B);
  static Color get orange => d ? const Color(0xFFE8873A) : const Color(0xFFD9701F);
  static Color get red => d ? const Color(0xFFE5484D) : const Color(0xFFD43A40);
  static Color get green => d ? const Color(0xFF4CAF7A) : const Color(0xFF2E9460);
  static Color get blue => d ? const Color(0xFF5B8DEF) : const Color(0xFF3A6FD8);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final loggedIn = await Api.restoreSession();
  runApp(AgapApp(startLoggedIn: loggedIn));
}

class AgapApp extends StatelessWidget {
  final bool startLoggedIn;
  const AgapApp({super.key, this.startLoggedIn = false});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: darkMode,
    builder: (_, dark, _) => MaterialApp(
      title: 'AGAP',
      navigatorKey: navKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: dark ? Brightness.dark : Brightness.light,
        scaffoldBackgroundColor: C.bg,
        colorScheme: dark
            ? ColorScheme.dark(primary: C.cream, surface: C.surface)
            : ColorScheme.light(primary: C.cream, surface: C.surface),
        fontFamily: 'Roboto',
      ),
      home: startLoggedIn ? const Shell() : const LoginScreen(),
    ),
  );
}

class Report {
  final String id, type, injury, place, date, status, description, title, severity, time;
  final int? dbId, injuries, fatalities;
  final double? lat, lng;
  final Map<String, dynamic> raw; // buong JSON galing server (status, created_at, atbp.)
  Report(this.id, this.type, this.injury, this.place, this.date, this.status,
      [this.description = '', this.dbId, this.lat, this.lng,
       this.title = '', this.severity = '', this.time = '', this.injuries, this.fatalities,
       this.raw = const {}]);

  String get statusKey => '${raw['status'] ?? ''}'; // hal. needs_clarification
  String get severityKey => '${raw['severity'] ?? ''}';

  factory Report.fromJson(Map<String, dynamic> j) => Report(
        '${j['report_reference'] ?? ''}',
        '${j['category_name'] ?? j['title'] ?? 'Other'}',
        kInjuryLabel[j['injury_status']] ?? 'Unknown',
        '${j['location'] ?? ''}',
        prettyDate('${j['accident_date'] ?? ''}'),
        kStatusLabel[j['status']] ?? 'Sent',
        '${j['description'] ?? ''}',
        j['id'] as int?,
        double.tryParse('${j['latitude'] ?? ''}'), // DECIMAL comes back as a string from Postgres
        double.tryParse('${j['longitude'] ?? ''}'),
        '${j['title'] ?? ''}',
        kSeverityLabel[j['severity']] ?? '',
        prettyTime('${j['accident_time'] ?? ''}'),
        int.tryParse('${j['injuries'] ?? ''}'),
        int.tryParse('${j['fatalities'] ?? ''}'),
        j,
      );
}

// Isang napiling larawan (nasa memory muna hanggang ma-upload sa server)
class Photo {
  final String name;
  final Uint8List bytes;
  const Photo(this.name, this.bytes);
}

class Draft {
  String? type, injury, severity;
  String title = '', place = '', description = '';
  int injuries = 0, fatalities = 0, total = 1;
  final Set<String> vehicles = {};
  bool noVehicles = false, pinMode = false;
  bool whenEdited = false; // true kapag manual na pinalitan ang date/time
  String date = todayIso(), time = nowHm();
  final List<Photo> photos = []; // ina-upload pagkatapos magawa ang report
  double? lat, lng; // GPS / pinned coordinates (sent to the web database)
  String? draftId;

  void stampNow() {
    date = todayIso();
    time = nowHm();
  }

  void reset() {
    type = injury = severity = null;
    title = place = description = '';
    injuries = fatalities = 0;
    total = 1;
    vehicles.clear();
    noVehicles = pinMode = whenEdited = false;
    photos.clear();
    lat = lng = null;
    draftId = null;
    stampNow();
  }
}

final Draft draft = Draft();

Report? findReport(String id) {
  for (final r in reports.value) {
    if (r.id == id) return r;
  }
  return null;
}

String two(int n) => n.toString().padLeft(2, '0');

// Walang timezone conversion: YYYY-MM-DD lang ang kinukuha (ganito rin ang web, slice(0,10))
String prettyDate(String raw) {
  const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final p = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(raw);
  if (p == null) return raw;
  return '${m[int.parse(p[2]!) - 1]} ${p[3]}, ${p[1]}';
}

String prettyTime(String raw) { // '09:00:00' -> '9:00 AM'
  final p = raw.split(':');
  final h = p.length > 1 ? int.tryParse(p[0]) : null;
  if (h == null) return '';
  return '${h % 12 == 0 ? 12 : h % 12}:${p[1]} ${h >= 12 ? 'PM' : 'AM'}';
}

String nowHm() {
  final n = DateTime.now();
  return '${two(n.hour)}:${two(n.minute)}';
}

// Walang 'null' na text kapag walang laman ang field galing server
String txt(Object? v) {
  final t = '${v ?? ''}'.trim();
  return t == 'null' ? '' : t;
}

const _kMonths = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

// Timestamp galing server (ISO, may timezone) -> oras ng phone
DateTime? parseStamp(Object? raw) {
  final s = '${raw ?? ''}';
  if (s.isEmpty || s == 'null') return null;
  return DateTime.tryParse(s)?.toLocal();
}

// "Oct 14, 09:12"
String stampLabel(Object? raw) {
  final d = parseStamp(raw);
  if (d == null) return '';
  return '${_kMonths[d.month - 1]} ${d.day}, ${two(d.hour)}:${two(d.minute)}';
}

// Parehong pananalita ng web: "just now", "5 min ago", "3 h ago", "2 d ago"
String timeAgo(Object? raw) {
  final d = parseStamp(raw);
  if (d == null) return 'time unknown';
  final min = DateTime.now().difference(d).inMinutes;
  if (min < 1) return 'just now';
  if (min < 60) return '$min min ago';
  final h = (min / 60).round();
  if (h < 24) return '$h h ago';
  return '${(h / 24).round()} d ago';
}

Future<Position> getGpsPosition() async {
  if (!await Geolocator.isLocationServiceEnabled()) {
    throw 'Location is off. Turn on GPS in your phone settings.';
  }
  var perm = await Geolocator.checkPermission();
  if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
  if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
    throw 'Location permission is needed. Allow it in the app settings.';
  }
  return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 15)));
}

String nameFromEmail(String email) {
  final local = email.trim().split('@').first;
  final words = local.split(RegExp(r'[._\-\s]+')).where((w) => w.isNotEmpty);
  return words.map((w) => w[0].toUpperCase() + w.substring(1)).join(' ');
}

String initialsOf(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  return parts.take(2).map((w) => w[0].toUpperCase()).join();
}

String? emailErr(String v) {
  final e = v.trim();
  if (e.isEmpty) return 'Enter your email';
  if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(e)) return 'Enter a valid email';
  return null;
}

String? mobileErr(String v) {
  final m = v.replaceAll(RegExp(r'[\s-]'), '');
  if (m.isEmpty) return 'Enter your mobile number';
  if (!RegExp(r'^(09|\+639)\d{9}$').hasMatch(m)) return 'Use a valid number, e.g. 09xx xxx xxxx';
  return null;
}

class UserProfile {
  final String name, mobile, email;

  const UserProfile(this.name, this.mobile, this.email);
}

final ValueNotifier<UserProfile> user =
    ValueNotifier(const UserProfile('', '', ''));

class AlertItem {
  final String title, body, reportId, status;
  final int? dbId;
  bool unread;
  AlertItem(this.title, this.body, this.reportId, this.status,
      {this.unread = true, this.dbId});

  factory AlertItem.fromJson(Map<String, dynamic> n) {
    final ev = '${n['event'] ?? ''}';
    final ref = '${n['report_reference'] ?? ''}';
    // report.<status> = nagbago ang status ng report
    final label = ev.startsWith('report.') ? kStatusLabel[ev.substring(7)] : null;
    return AlertItem(
      ev == 'report.submitted' ? 'Report sent'
          : ev == 'report.updated' ? 'Report updated'
          : ev == 'evidence.added' ? 'Photo added'
          : ev == 'findings.added' ? 'Findings added'
          : ev == 'report.needs_clarification' ? 'More info needed'
          : label != null ? 'Report ${label.toLowerCase()}' : 'Report update',
      '${n['message'] ?? ''}', ref, findReport(ref)?.status ?? 'Sent',
      unread: !(n['is_read'] == true || n['is_read'] == 1), dbId: n['id'] as int?);
  }
}

final ValueNotifier<List<Report>> reports = ValueNotifier(<Report>[]);
final ValueNotifier<List<AlertItem>> alerts = ValueNotifier(<AlertItem>[]);



Widget screenHeader(BuildContext c, String title) => Padding(
  padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
  child: Row(children: [
    IconButton(
      onPressed: () => Navigator.pop(c),
      icon: const Icon(Icons.arrow_back_ios_new, size: 16)),
    Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
  ]),
);

class PrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool outlined;

  const PrimaryButton(this.label, this.onTap, {super.key, this.outlined = false});

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    height: 48,
    child: TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        backgroundColor: outlined ? Colors.transparent : C.cream,
        foregroundColor: outlined ? C.text : C.bg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: outlined ? BorderSide(color: C.border) : BorderSide.none,
        ),
      ),
      child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
    ),
  );
}

class Field extends StatelessWidget {
  final String label, hint;
  final bool obscure;
  final int maxLines;
  final String? error;
  final ValueChanged<String>? onChanged;
  final String? initial;
  final TextEditingController? controller;
  final TextInputType? keyboard;

  const Field(this.label, this.hint,
    {super.key, this.obscure = false, this.maxLines = 1, this.error, this.onChanged, this.initial, this.controller, this.keyboard});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: TextStyle(fontSize: 12, color: C.muted)),
      const SizedBox(height: 6),
      TextFormField(
        controller: controller,
        initialValue: controller == null ? initial : null,
        obscureText: obscure,
        keyboardType: keyboard,
        maxLines: maxLines,
        onChanged: onChanged,
        style: TextStyle(fontSize: 14, color: C.text),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: C.muted, fontSize: 13),
          filled: true,
          fillColor: C.surface,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: error != null ? C.red : C.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: error != null ? C.red : C.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: error != null ? C.red : C.cream),
          ),
        ),
      ),
      if (error != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(error!, style: TextStyle(color: C.red, fontSize: 11)),
        ),
    ]),
  );
}

class Tag extends StatelessWidget {
  final String text;
  final Color color;

  const Tag(this.text, this.color, {super.key});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .15),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: color.withValues(alpha: .5)),
    ),
    child: Text(text, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600)),
  );
}

// Kulay bawat status, kapareho ng web (--status-*). `key` ay ang status ng server.
Color statusColorOf(String key) {
  final d = C.d;
  switch (key) {
    case 'submitted': return d ? const Color(0xFFA9B4C2) : const Color(0xFF6F7C8C);
    case 'under_review': return d ? const Color(0xFFF5C033) : const Color(0xFFB7860B);
    case 'needs_clarification': return d ? const Color(0xFFF59A4A) : const Color(0xFFD9701F);
    case 'verified': return d ? const Color(0xFF2FD3C0) : const Color(0xFF178E80);
    case 'assigned': return d ? const Color(0xFF9B7BF2) : const Color(0xFF6D4FD0);
    case 'in_progress': return C.blue;
    case 'resolved': return C.green;
    case 'rejected': return C.red;
    default: return C.muted;
  }
}

// Para sa label ng app ("Reviewing", "Needs info", ...)
Color statusColor(String label) {
  for (final e in kStatusLabel.entries) {
    if (e.value == label) return statusColorOf(e.key);
  }
  return C.muted;
}

Color severityColor(String key) {
  switch (key) {
    case 'minor': return C.green;
    case 'moderate': return statusColorOf('under_review');
    case 'major': return C.orange;
    case 'fatal': return C.red;
    default: return C.muted;
  }
}

class Card1 extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;

  const Card1({super.key, required this.child, this.padding = const EdgeInsets.all(14), this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: C.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: C.border),
      ),
      child: child,
    ),
  );
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  String email = '';
  String password = '';
  bool submitted = false;
  bool loading = false;
  String? serverError;

  String? get emailError {
    if (!submitted) return null;
    final e = email.trim();
    if (e.isEmpty) return 'Enter your email';
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(e)) {
      return 'Enter a valid email';
    }
    return null;
  }

  String? get passwordError =>
      submitted && password.isEmpty ? 'Enter your password' : null;

  Future<void> _login() async {
    setState(() => submitted = true);
    if (emailError != null || passwordError != null) return;
    setState(() { loading = true; serverError = null; });
    try {
      await Api.login(email.trim(), password);
      await refreshAll();
      if (!mounted) return;
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const Shell()));
    } on ApiException catch (e) {
      if (mounted) setState(() => serverError = e.message);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Align(alignment: Alignment.centerRight, child: ThemeToggle()),
          const SizedBox(height: 16),
          const Center(child: AgapLogo(width: 270)),
          const SizedBox(height: 28),
          const Text('Log in', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 14),
          Field('Email', 'name@email.com',
            error: emailError,
            onChanged: (v) => setState(() => email = v)),
          Field('Password', 'Enter your password',
            obscure: true,
            error: passwordError ?? serverError,
            onChanged: (v) => setState(() => password = v)),
          const SizedBox(height: 16),
          PrimaryButton(loading ? 'Logging in...' : 'Log in', loading ? () {} : _login),
          const SizedBox(height: 16),
          Center(
            child: GestureDetector(
              onTap: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => const CreateAccountScreen())),
              child: Text.rich(TextSpan(
                text: 'No account yet? ',
                style: TextStyle(color: C.muted, fontSize: 12),
                children: [
                  TextSpan(
                    text: 'Create an account',
                    style: TextStyle(color: C.cream, fontWeight: FontWeight.w600))
                ],
              )),
            ),
          ),
        ]),
      ),
    ),
  );
}

class CreateAccountScreen extends StatefulWidget {
  const CreateAccountScreen({super.key});

  @override
  State<CreateAccountScreen> createState() => _CreateAccountScreenState();
}

class _CreateAccountScreenState extends State<CreateAccountScreen> {
  String name = '', mobile = '', email = '', password = '';
  bool submitted = false;
  bool loading = false;
  String? serverError;

  String? get nameError =>
      submitted && name.trim().isEmpty ? 'Enter your full name' : null;

  String? get mobileError => submitted ? mobileErr(mobile) : null;
  String? get emailError => submitted ? emailErr(email) : null;

  String? get passError {
    if (!submitted) return null;
    if (password.isEmpty) return 'Enter a password';
    if (password.length < 8) return 'At least 8 characters';
    return null;
  }

  Future<void> _create() async {
    setState(() => submitted = true);
    if (nameError != null || mobileError != null || emailError != null || passError != null) return;
    setState(() { loading = true; serverError = null; });
    final mail = email.trim().toLowerCase();
    try {
      await Api.register(name.trim(), mobile.trim(), mail, password);
      await Api.login(mail, password);
      await refreshAll();
      if (!mounted) return;
      Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (_) => const Shell()), (_) => false);
    } on ApiException catch (e) {
      if (mounted) setState(() => serverError = e.status == 409 ? 'That email is already registered' : e.message);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      backgroundColor: C.bg,
      elevation: 0,
      title: const Text('Create account', style: TextStyle(fontSize: 15)),
    ),
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(children: [
          Field('Full name', 'Juan Dela Cruz',
            error: nameError, onChanged: (v) => setState(() => name = v)),
          Field('Mobile number', '09xx xxx xxxx',
            error: mobileError, onChanged: (v) => setState(() => mobile = v)),
          Field('Email', 'name@email.com',
            error: emailError, onChanged: (v) => setState(() => email = v)),
          Field('Password', 'At least 8 characters',
            obscure: true,
            error: passError,
            onChanged: (v) => setState(() => password = v)),
          const SizedBox(height: 10),
          if (serverError != null) Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(serverError!, style: TextStyle(color: C.red, fontSize: 12))),
          PrimaryButton(loading ? 'Creating account...' : 'Create account', loading ? () {} : _create),
          const SizedBox(height: 14),
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Text.rich(TextSpan(
              text: 'Already have an account? ',
              style: TextStyle(color: C.muted, fontSize: 12),
              children: [
                TextSpan(text: 'Log in', style: TextStyle(color: C.cream, fontWeight: FontWeight.w600))
              ],
            )),
          ),
        ]),
      ),
    ),
  );
}

class Shell extends StatefulWidget {
  final int initialIndex;

  const Shell({super.key, this.initialIndex = 0});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> with WidgetsBindingObserver {
  late int i = widget.initialIndex;
  Timer? _poll;
  bool _refreshing = false;
  final Set<int> _seenAlerts = {};
  late bool _alertsPrimed = alerts.value.isNotEmpty;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    for (final a in alerts.value) {
      if (a.dbId != null) _seenAlerts.add(a.dbId!);
    }
    alerts.addListener(_onAlerts);
    WidgetsBinding.instance.addPostFrameCallback((_) => _silentRefresh()); // load agad ang reports pagbukas
    // kusang nagre-refresh ng reports/alerts kada 10 segundo (para magbago ang status nang walang restart)
    _poll = Timer.periodic(const Duration(seconds: 10), (_) => _silentRefresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    alerts.removeListener(_onAlerts);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Lumalabas ang banner kapag may bagong alert habang bukas ang app (hindi na kailangang buksan ang Alerts)
  void _onAlerts() {
    final list = alerts.value;
    final fresh = [
      for (final a in list)
        if (a.unread && a.dbId != null && !_seenAlerts.contains(a.dbId)) a
    ];
    for (final a in list) {
      if (a.dbId != null) _seenAlerts.add(a.dbId!);
    }
    if (!_alertsPrimed) { // unang load pagbukas ng app: huwag i-banner ang mga lumang alert
      _alertsPrimed = true;
      return;
    }
    if (fresh.isEmpty || !mounted) return;
    final a = fresh.first;
    final text = a.body.isEmpty ? a.title : '${a.title}: ${a.body}';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 6),
        content: Text(fresh.length > 1 ? '$text (+${fresh.length - 1} more)' : text),
        action: SnackBarAction(
          label: 'View',
          onPressed: () {
            if (!mounted) return;
            Navigator.of(context).popUntil((r) => r.isFirst);
            setState(() => i = 3);
          },
        ),
      ));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _silentRefresh();
  }

  Future<void> _silentRefresh() async {
    if (_refreshing || Api.token == null) return;
    _refreshing = true;
    try {
      await refreshAll();
    } catch (_) {} finally {
      _refreshing = false;
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: IndexedStack(index: i, children: [
        HomeTab(
          goReports: () => setState(() => i = 1),
          goAlerts: () => setState(() => i = 3)),
        const MyReportsTab(),
        const MapTab(),
        const AlertsTab(),
      ]),
    ),
    bottomNavigationBar: Container(
      decoration: BoxDecoration(
        color: C.surface, border: Border(top: BorderSide(color: C.border))),
      child: SafeArea(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _nav(0, Icons.dashboard_outlined, 'Dashboard'),
            _nav(1, Icons.description_outlined, 'Reports'),
            _nav(2, Icons.map_outlined, 'Map'),
            _nav(3, Icons.notifications_none, 'Alerts'),
          ],
        ),
      ),
    ),
  );

  Widget _nav(int idx, IconData icon, String label) {
    final sel = i == idx;
    return GestureDetector(
      onTap: () => setState(() => i = idx),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: sel ? C.cream : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(children: [
          Icon(icon, size: 18, color: sel ? C.bg : C.muted),
          if (sel) ...[
            const SizedBox(width: 6),
            Text(label,
              style: TextStyle(color: C.bg, fontSize: 12, fontWeight: FontWeight.w700)),
          ],
        ]),
      ),
    );
  }
}

class HomeTab extends StatelessWidget {
  final VoidCallback goReports, goAlerts;

  const HomeTab({super.key, required this.goReports, required this.goAlerts});

  // Dashboard ng web para sa reporter: alert strip, 4 na bilang, at Recent reports
  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: refreshAll,
    child: ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(18),
      children: [
        Row(children: [
          const AgapLogo(width: 170),
          const Spacer(),
          const ThemeToggle(),
          ProfileButton(goReports: goReports, goAlerts: goAlerts),
        ]),
        const SizedBox(height: 18),
        ValueListenableBuilder<bool>(
          valueListenable: reportsLoaded,
          builder: (_, loaded, _) => ValueListenableBuilder<List<Report>>(
            valueListenable: reports,
            builder: (_, list, _) => _content(context, list, loaded),
          ),
        ),
      ],
    ),
  );

  Widget _content(BuildContext context, List<Report> list, bool loaded) {
    final pending = list.where((r) => r.statusKey == 'submitted' || r.statusKey == 'under_review').length;
    final resolved = list.where((r) => r.statusKey == 'resolved').length;
    final critical = list.where((r) => r.severityKey == 'fatal' || r.severityKey == 'major').toList()
      ..sort((a, b) => (parseStamp(b.raw['created_at']) ?? DateTime(2000))
          .compareTo(parseStamp(a.raw['created_at']) ?? DateTime(2000)));
    final recent = list.take(5).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _alertStrip(loaded, critical, pending),
      const SizedBox(height: 16),
      const Text('Dashboard', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
      ValueListenableBuilder<UserProfile>(
        valueListenable: user,
        builder: (_, u, _) => Text('Welcome, ${u.name} (reporter)',
          style: TextStyle(color: C.muted, fontSize: 12)),
      ),
      const SizedBox(height: 14),
      GestureDetector(
        onTap: () {
          draft.reset();
          Navigator.push(context, MaterialPageRoute(builder: (_) => const Step1()));
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(color: C.cream, borderRadius: BorderRadius.circular(28)),
          child: Row(children: [
            Icon(Icons.warning_amber_rounded, color: C.bg, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text('Report new accident',
                style: TextStyle(color: C.bg, fontWeight: FontWeight.w700, fontSize: 15))),
            Icon(Icons.arrow_forward, color: C.bg),
          ]),
        ),
      ),
      if (loaded) ...[
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: _stat('${list.length}', 'Visible to you')),
          const SizedBox(width: 10),
          Expanded(child: _stat('$pending', 'Awaiting review')),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _stat('$resolved', 'Resolved')),
          const SizedBox(width: 10),
          Expanded(child: _stat('${critical.length}', 'Major or fatal')),
        ]),
        const SizedBox(height: 6),
        Text('Counts cover only your own reports.',
          style: TextStyle(color: C.muted, fontSize: 10)),
      ],
      const SizedBox(height: 16),
      Card1(
        onTap: goAlerts,
        child: ValueListenableBuilder<List<AlertItem>>(
          valueListenable: alerts,
          builder: (_, al, _) {
            final n = al.where((a) => a.unread).length;
            return Row(children: [
              Icon(Icons.notifications_none, color: C.cream),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Alerts', style: TextStyle(fontWeight: FontWeight.w700)),
                  Text(n == 0 ? 'No new updates' : '$n new update${n == 1 ? '' : 's'}',
                    style: TextStyle(color: C.muted, fontSize: 11)),
                ])),
              if (n > 0)
                Container(
                  width: 18,
                  height: 18,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: C.orange, shape: BoxShape.circle),
                  child: Text('$n',
                    style: TextStyle(color: C.bg, fontSize: 10, fontWeight: FontWeight.w800)),
                )
              else
                Icon(Icons.chevron_right, color: C.muted),
            ]);
          },
        ),
      ),
      const SizedBox(height: 18),
      Row(children: [
        const Expanded(
          child: Text('Recent reports',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15))),
        GestureDetector(
          onTap: goReports,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Text('View all',
              style: TextStyle(color: C.cream, fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ),
      ]),
      const SizedBox(height: 8),
      if (!loaded)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Center(child: Text('Loading...', style: TextStyle(color: C.muted, fontSize: 12))),
        )
      else if (recent.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Center(child: Text('No reports yet.', style: TextStyle(color: C.muted, fontSize: 12))),
        )
      else
        for (final r in recent) ReportTile(r),
      const SizedBox(height: 8),
    ]);
  }

  Widget _alertStrip(bool loaded, List<Report> critical, int pending) {
    final tone = !loaded ? C.blue : critical.isNotEmpty ? C.red : C.green;
    final headline = !loaded
        ? 'Loading the situation…'
        : critical.isNotEmpty
            ? '${critical.length} major or fatal accident ${critical.length == 1 ? 'report' : 'reports'}'
            : 'No major or fatal accidents on record';
    String? detail;
    if (loaded) {
      if (critical.isNotEmpty) {
        final c = critical.first;
        detail = 'Most recent: ${c.id} at ${c.place}, ${timeAgo(c.raw['created_at'])}'
            '${critical.length > 1 ? ' · +${critical.length - 1} more' : ''}';
      } else {
        detail = '$pending ${pending == 1 ? 'report' : 'reports'} awaiting review';
      }
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: tone.withValues(alpha: .45)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: tone, shape: BoxShape.circle),
          child: Text(loaded ? '!' : 'i',
            style: TextStyle(color: C.bg, fontSize: 12, fontWeight: FontWeight.w800)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(headline, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
            if (detail != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(detail, style: TextStyle(color: C.muted, fontSize: 11)),
              ),
          ])),
      ]),
    );
  }

  Widget _stat(String value, String label) => Card1(
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(value, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
      const SizedBox(height: 2),
      Text(label, style: TextStyle(color: C.muted, fontSize: 11)),
    ]),
  );
}

class StepScaffold extends StatelessWidget {
  final int step;
  final String title, buttonLabel;
  final Widget body;
  final VoidCallback onNext;

  const StepScaffold({
    super.key,
    required this.step,
    required this.title,
    required this.buttonLabel,
    required this.body,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
          child: Row(children: [
            IconButton(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.arrow_back_ios_new, size: 16)),
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Step $step of 5', style: TextStyle(color: C.muted, fontSize: 11)),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: step / 5,
                minHeight: 4,
                backgroundColor: C.surface2,
                valueColor: AlwaysStoppedAnimation(C.cream),
              ),
            ),
          ]),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(18), child: body)),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
          child: PrimaryButton(buttonLabel, onNext),
        ),
      ]),
    ),
  );
}

class OptionCard extends StatelessWidget {
  final String title, sub;
  final bool selected;
  final VoidCallback onTap;

  const OptionCard(this.title, this.sub, this.selected, this.onTap, {super.key});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: selected ? C.cream : C.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: selected ? C.cream : C.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 13,
            color: selected ? C.bg : C.text)),
        if (sub.isNotEmpty)
          Text(sub,
            style: TextStyle(fontSize: 10, color: selected ? C.bg.withValues(alpha: .7) : C.muted)),
      ]),
    ),
  );
}

class Grid2 extends StatelessWidget {
  final List<Widget> children;

  const Grid2(this.children, {super.key});

  @override
  Widget build(BuildContext context) => GridView.count(
    crossAxisCount: 2,
    shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    crossAxisSpacing: 8,
    mainAxisSpacing: 8,
    childAspectRatio: 2.1,
    children: children,
  );
}

class CounterRow extends StatelessWidget {
  final String label;
  final int value;
  final ValueChanged<int> onChanged;

  const CounterRow(this.label, this.value, this.onChanged, {super.key});

  Widget _btn(IconData i, VoidCallback t) => GestureDetector(
    onTap: t,
    child: Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        shape: BoxShape.circle, color: C.surface, border: Border.all(color: C.border)),
      child: Icon(i, size: 18),
    ),
  );

  @override
  Widget build(BuildContext context) => Row(children: [
    Expanded(child: Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
    _btn(Icons.remove, () { if (value > 0) onChanged(value - 1); }),
    Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Text('$value', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
    ),
    _btn(Icons.add, () { if (value < 255) onChanged(value + 1); }),
  ]);
}

class Step1 extends StatefulWidget {
  const Step1({super.key});

  @override
  State<Step1> createState() => _Step1State();
}

class _Step1State extends State<Step1> {
  bool showError = false;

  @override
  Widget build(BuildContext context) {
    final types = {
      'Crash': 'Vehicles collided',
      'Hit and run': 'Driver left the scene',
      'Flipped over': 'Vehicle overturned',
      'Person hit': 'Pedestrian or cyclist',
      'Other': 'Something else',
    };
    const injuries = ['None', 'Injuries', 'Fatalities', 'Unknown'];
    const severities = ['Minor', 'Moderate', 'Major', 'Fatal'];
    final typeErr = showError && draft.type == null;
    final injErr = showError && draft.injury == null;
    final showCounts = draft.injury == 'Injuries' || draft.injury == 'Fatalities';
    return StepScaffold(
      step: 1,
      title: 'Report an accident',
      buttonLabel: 'Next: Vehicles',
      onNext: () {
        if (draft.type == null || draft.injury == null) {
          setState(() => showError = true);
          return;
        }
        Navigator.push(context, MaterialPageRoute(builder: (_) => const Step2()));
      },
      body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text.rich(TextSpan(text: 'What happened? ', children: [
          TextSpan(text: '*', style: TextStyle(color: C.red))
        ]), style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
        if (typeErr)
          Text("Pick what happened", style: TextStyle(color: C.red, fontSize: 11)),
        const SizedBox(height: 10),
        Grid2([
          for (final e in types.entries)
            OptionCard(e.key, e.value, draft.type == e.key,
              () => setState(() => draft.type = e.key)),
        ]),
        const SizedBox(height: 20),
        Text.rich(TextSpan(text: 'Injury status ', children: [
          TextSpan(text: '*', style: TextStyle(color: C.red))
        ]), style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
        if (injErr)
          Text("Choose the injury status", style: TextStyle(color: C.red, fontSize: 11)),
        const SizedBox(height: 10),
        Grid2([
          for (final s in injuries)
            OptionCard(s, '', draft.injury == s, () => setState(() {
              draft.injury = s;
              if (s == 'Injuries' && draft.injuries == 0) draft.injuries = 1;
              if (s == 'Fatalities' && draft.fatalities == 0) draft.fatalities = 1;
              if (s == 'None' || s == 'Unknown') {
                draft.injuries = 0;
                draft.fatalities = 0;
              }
            })),
        ]),
        if (showCounts) ...[
          const SizedBox(height: 14),
          CounterRow('People injured', draft.injuries, (v) => setState(() => draft.injuries = v)),
          const SizedBox(height: 10),
          CounterRow('People who died', draft.fatalities, (v) => setState(() => draft.fatalities = v)),
        ],
        const SizedBox(height: 20),
        const Text('Severity', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
        Text('Optional. Tap again to clear.', style: TextStyle(color: C.muted, fontSize: 11)),
        const SizedBox(height: 10),
        Grid2([
          for (final s in severities)
            OptionCard(s, '', draft.severity == s,
              () => setState(() => draft.severity = draft.severity == s ? null : s)),
        ]),
      ]),
    );
  }
}

class Step2 extends StatefulWidget {
  const Step2({super.key});

  @override
  State<Step2> createState() => _Step2State();
}

class _Step2State extends State<Step2> {
  bool showError = false;

  int get _picked => draft.vehicles.length;
  int get _minTotal => _picked < 1 ? 1 : _picked; // hindi pwedeng mas kaunti ang total kaysa sa napiling uri

  @override
  Widget build(BuildContext context) {
    const vehicles = ['Motorcycle', 'Car', 'Truck', 'Bus'];
    return StepScaffold(
      step: 2,
      title: 'Which vehicles?',
      buttonLabel: 'Next: Place',
      onNext: () {
        if (!draft.noVehicles && draft.vehicles.isEmpty) {
          setState(() => showError = true);
          return;
        }
        Navigator.push(context, MaterialPageRoute(builder: (_) => const Step3()));
      },
      body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Vehicles involved',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
        const SizedBox(height: 4),
        Text('Select all that apply', style: TextStyle(color: C.muted, fontSize: 11)),
        if (showError && !draft.noVehicles && draft.vehicles.isEmpty)
          Text('Pick the vehicles, or tap "No vehicles involved"',
            style: TextStyle(color: C.red, fontSize: 11)),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final v in vehicles)
            ChoiceChip(
              label: Text(v),
              selected: draft.vehicles.contains(v),
              selectedColor: C.cream,
              backgroundColor: C.surface,
              labelStyle: TextStyle(
                color: draft.vehicles.contains(v) ? C.bg : C.text,
                fontWeight: FontWeight.w600,
                fontSize: 12),
              side: BorderSide(color: C.border),
              onSelected: (s) => setState(() {
                s ? draft.vehicles.add(v) : draft.vehicles.remove(v);
                if (draft.noVehicles) {
                  draft.noVehicles = false;
                  draft.total = 1;
                }
                if (draft.total < _minTotal) draft.total = _minTotal; // 2 uri = hindi bababa sa 2
              }),
            ),
        ]),
        const SizedBox(height: 12),
        GestureDetector(
          onTap: () => setState(() {
            draft.noVehicles = !draft.noVehicles;
            if (draft.noVehicles) {
              draft.vehicles.clear();
              draft.total = 0;
            } else {
              draft.total = 1;
            }
          }),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 12),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: draft.noVehicles ? C.cream : C.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: C.border),
            ),
            child: Text('No vehicles involved',
              style: TextStyle(
                color: draft.noVehicles ? C.bg : C.text,
                fontWeight: FontWeight.w600,
                fontSize: 13)),
          ),
        ),
        const SizedBox(height: 24),
        const Text('Total vehicles involved',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
        const SizedBox(height: 4),
        Text(
          draft.noVehicles
              ? 'No vehicles involved, so the total is 0.'
              : 'Count every vehicle, e.g. 2 cars and 1 motorcycle = 3.',
          style: TextStyle(color: C.muted, fontSize: 11)),
        const SizedBox(height: 10),
        Opacity(
          opacity: draft.noVehicles ? .4 : 1,
          child: Row(children: [
            _round(Icons.remove, () {
              if (!draft.noVehicles && draft.total > _minTotal) setState(() => draft.total--);
            }),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22),
              child: Text('${draft.total}',
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
            ),
            _round(Icons.add, () {
              if (!draft.noVehicles && draft.total < 255) setState(() => draft.total++);
            }),
          ]),
        ),
      ]),
    );
  }

  Widget _round(IconData i, VoidCallback t) => GestureDetector(
    onTap: t,
    child: Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        shape: BoxShape.circle, color: C.surface, border: Border.all(color: C.border)),
      child: Icon(i, size: 18),
    ),
  );
}

class Step3 extends StatefulWidget {
  const Step3({super.key});

  @override
  State<Step3> createState() => _Step3State();
}

class _Step3State extends State<Step3> {
  static const _manila = LatLng(14.5995, 120.9842); // gitna ng map kapag wala pang GPS
  final MapController _map = MapController();
  late final TextEditingController _place = TextEditingController(text: draft.place);
  bool showError = false, showPinError = false, locating = false;
  bool _autoAddress = draft.place.isEmpty; // true = galing sa GPS, pwede pang palitan ng GPS
  String? gpsMsg;
  late final TextEditingController _lat = TextEditingController(text: draft.lat?.toStringAsFixed(6) ?? '');
  late final TextEditingController _lng = TextEditingController(text: draft.lng?.toStringAsFixed(6) ?? '');
  String? coordErr;

  void _applyManual() {
    final la = double.tryParse(_lat.text.trim());
    final ln = double.tryParse(_lng.text.trim());
    if (la == null || ln == null || la < -90 || la > 90 || ln < -180 || ln > 180) {
      setState(() => coordErr = 'Enter a valid latitude (-90 to 90) and longitude (-180 to 180).');
      return;
    }
    _autoAddress = true;
    _setPin(LatLng(la, ln), moveMap: true);
  }

  LatLng? get _pin => (draft.lat == null || draft.lng == null) ? null : LatLng(draft.lat!, draft.lng!);

  @override
  void initState() {
    super.initState();
    if (_pin == null) _useMyLocation(); // kusa nang kukunin ang GPS pagbukas ng step na ito
  }

  @override
  void dispose() {
    _place.dispose();
    _lat.dispose();
    _lng.dispose();
    super.dispose();
  }

  Future<Position> _getPosition() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw 'Location is off. Turn on GPS in your phone settings.';
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied) throw 'Location permission was denied.';
    if (perm == LocationPermission.deniedForever) {
      throw 'Location permission is blocked. Allow it in the app settings.';
    }
    return Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 15)));
  }

  Future<void> _useMyLocation() async {
    setState(() { locating = true; gpsMsg = null; });
    try {
      final p = await _getPosition();
      _setPin(LatLng(p.latitude, p.longitude), moveMap: true);
    } catch (e) {
      if (mounted) {
        setState(() => gpsMsg = '$e'.contains('TimeoutException')
          ? 'Could not get a GPS signal. Try again, or tap the map to place the pin.'
          : '$e');
      }
    } finally {
      if (mounted) setState(() => locating = false);
    }
  }

  void _setPin(LatLng p, {bool moveMap = false}) {
    if (!mounted) return;
    setState(() {
      draft.lat = p.latitude;
      draft.lng = p.longitude;
      showPinError = false;
      gpsMsg = null;
      _lat.text = p.latitude.toStringAsFixed(6);
      _lng.text = p.longitude.toStringAsFixed(6);
      coordErr = null;
    });
    if (moveMap) _map.move(p, 17);
    _fillAddress(p);
  }

  // Sinusubukang hanapin ang pangalan ng kalsada gamit ang OpenStreetMap (Nominatim).
  // Kapag walang internet o may error, tahimik lang; mano-mano pa ring pwedeng i-type.
  Future<void> _fillAddress(LatLng p) async {
    if (!_autoAddress && _place.text.trim().isNotEmpty) return;
    try {
      final res = await http.get(
        Uri.parse('https://nominatim.openstreetmap.org/reverse?format=jsonv2'
            '&lat=${p.latitude}&lon=${p.longitude}&zoom=18'),
        headers: {'User-Agent': kPackageName, 'Accept-Language': 'en'},
      ).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200 || !mounted) return;
      final name = '${(jsonDecode(res.body) as Map)['display_name'] ?? ''}'.trim();
      if (name.isEmpty || (!_autoAddress && _place.text.trim().isNotEmpty)) return;
      setState(() {
        _autoAddress = true;
        _place.text = name;
        draft.place = name;
        showError = false;
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => StepScaffold(
    step: 3,
    title: 'Where did it happen?',
    buttonLabel: 'Next: Photos and details',
    onNext: () {
      final noPlace = draft.place.trim().isEmpty;
      final noPin = _pin == null;
      if (noPlace || noPin) {
        setState(() { showError = noPlace; showPinError = noPin; });
        return;
      }
      Navigator.push(context, MaterialPageRoute(builder: (_) => const Step4()));
    },
    body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        _seg('Use my location', locating ? Icons.hourglass_top : Icons.my_location,
            true, locating ? () {} : _useMyLocation),
      ]),
      const SizedBox(height: 14),
      Container(
        height: 260,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: showPinError ? C.red : C.border),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(13),
          child: FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: _pin ?? _manila,
              initialZoom: _pin == null ? 12 : 17,
              interactionOptions: InteractionOptions(
                  flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
              onTap: (_, point) {
                _autoAddress = true; // bagong pin = bagong address
                _setPin(point);
              },
            ),
            children: [
              appTileLayer(),
              if (_pin != null)
                MarkerLayer(markers: [
                  Marker(
                    point: _pin!,
                    width: 44,
                    height: 44,
                    alignment: Alignment.topCenter,
                    child: Icon(Icons.location_on, size: 44, color: C.red),
                  ),
                ]),
              const SimpleAttributionWidget(
                  source: Text('Mapbox, OpenStreetMap contributors')),
            ],
          ),
        ),
      ),
      const SizedBox(height: 6),
      if (gpsMsg != null)
        Text(gpsMsg!, style: TextStyle(color: C.red, fontSize: 11))
      else if (showPinError)
        Text('Pin the location first: use GPS or tap the map.',
            style: TextStyle(color: C.red, fontSize: 11))
      else if (_pin != null)
        Text('Pinned: ${_pin!.latitude.toStringAsFixed(5)}, ${_pin!.longitude.toStringAsFixed(5)}  -  tap the map to move the pin',
            style: TextStyle(color: C.muted, fontSize: 10))
      else
        Text(locating ? 'Getting your location...' : 'Tap the map to drop the pin',
            style: TextStyle(color: C.muted, fontSize: 10)),
      const SizedBox(height: 14),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: Field('Latitude', '14.864640', controller: _lat,
          keyboard: const TextInputType.numberWithOptions(decimal: true, signed: true))),
        const SizedBox(width: 8),
        Expanded(child: Field('Longitude', '120.796770', controller: _lng,
          keyboard: const TextInputType.numberWithOptions(decimal: true, signed: true))),
      ]),
      if (coordErr != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(coordErr!, style: TextStyle(color: C.red, fontSize: 11))),
      PrimaryButton('Set pin from coordinates', _applyManual, outlined: true),
      const SizedBox(height: 16),
      Field('Street / landmark *', '123 Brighton Ave, Bulacan',
        controller: _place,
        error: showError && draft.place.trim().isEmpty ? 'Enter the street or landmark' : null,
        onChanged: (v) { draft.place = v; _autoAddress = false; if (showError) setState(() {}); }),
    ]),
  );

  Widget _seg(String t, IconData icon, bool sel, VoidCallback tap) => Expanded(
    child: GestureDetector(
      onTap: tap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: sel ? C.cream : C.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: C.border),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 15, color: sel ? C.bg : C.text),
          const SizedBox(width: 6),
          Text(t,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: sel ? C.bg : C.text)),
        ]),
      ),
    ),
  );
}

class Step4 extends StatefulWidget {
  const Step4({super.key});

  @override
  State<Step4> createState() => _Step4State();
}

class _Step4State extends State<Step4> {
  bool showError = false;
  final ImagePicker _picker = ImagePicker();
  static const int _maxPhotos = 5;
  String? photoMsg;

  @override
  void initState() {
    super.initState();
    if (!draft.whenEdited) draft.stampNow(); // kasalukuyang date at oras, hindi 09:00
  }

  Future<void> _addPhotos(bool camera) async {
    if (draft.photos.length >= _maxPhotos) {
      setState(() => photoMsg = 'You can attach up to $_maxPhotos photos.');
      return;
    }
    try {
      List<XFile> files = [];
      if (camera) {
        final x = await _picker.pickImage(
            source: ImageSource.camera, imageQuality: 80, maxWidth: 1600);
        if (x != null) files = [x];
      } else {
        files = await _picker.pickMultiImage(imageQuality: 80, maxWidth: 1600);
      }
      var skipped = 0;
      for (final f in files) {
        if (draft.photos.length >= _maxPhotos) {
          skipped++;
          continue;
        }
        final bytes = await f.readAsBytes();
        if (bytes.length > 10 * 1024 * 1024 || Api.sniffMime(bytes) == null) {
          skipped++;
          continue;
        }
        draft.photos.add(Photo(f.name, bytes));
      }
      if (mounted) {
        setState(() => photoMsg = skipped > 0
            ? '$skipped photo(s) skipped (max $_maxPhotos, JPG/PNG/WebP, under 10 MB).'
            : null);
      }
    } catch (_) {
      if (mounted) {
        setState(() => photoMsg = 'Could not open the camera or gallery. Check the app permissions.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final err = showError && draft.description.trim().isEmpty;
    return StepScaffold(
      step: 4,
      title: 'Add details',
      buttonLabel: 'Next: Review',
      onNext: () {
        if (draft.title.trim().length < 3 || draft.description.trim().isEmpty) {
          setState(() => showError = true);
          return;
        }
        final when = DateTime.tryParse('${draft.date} ${draft.time}');
        if (when != null && when.isAfter(DateTime.now().add(const Duration(minutes: 1)))) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('The date and time cannot be in the future.')));
          return;
        }
        Navigator.push(context, MaterialPageRoute(builder: (_) => const Step5()));
      },
      body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Field('Title *', 'e.g. Motorcycle crash near the market',
          initial: draft.title,
          error: showError && draft.title.trim().length < 3
              ? 'Enter a short title (at least 3 characters)' : null,
          onChanged: (v) {
            draft.title = v;
            if (showError) setState(() {});
          }),
        Text('Photos help responders (optional)',
          style: TextStyle(color: C.muted, fontSize: 11)),
        const SizedBox(height: 10),
        Row(children: [
          _photoBtn(Icons.photo_camera_outlined, 'Take photo', true),
          const SizedBox(width: 8),
          _photoBtn(Icons.photo_library_outlined, 'Choose photos', false),
        ]),
        if (draft.photos.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Wrap(spacing: 8, runSpacing: 8, children: [
              for (var i = 0; i < draft.photos.length; i++)
                Stack(clipBehavior: Clip.none, children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.memory(draft.photos[i].bytes,
                        width: 72, height: 72, fit: BoxFit.cover, gaplessPlayback: true),
                  ),
                  Positioned(
                    top: -6,
                    right: -6,
                    child: GestureDetector(
                      onTap: () => setState(() => draft.photos.removeAt(i)),
                      child: Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                            color: C.red, shape: BoxShape.circle,
                            border: Border.all(color: C.bg, width: 2)),
                        child: const Icon(Icons.close, size: 12, color: Colors.white),
                      ),
                    ),
                  ),
                ]),
            ]),
          ),
        if (draft.photos.isNotEmpty || photoMsg != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              photoMsg ?? '${draft.photos.length} of $_maxPhotos photos added',
              style: TextStyle(
                  color: photoMsg != null ? C.red : C.cream, fontSize: 11)),
          ),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: _pick('Date *', draft.date, Icons.calendar_today_outlined, _pickDate)),
          const SizedBox(width: 8),
          Expanded(child: _pick('Time *', draft.time, Icons.access_time, _pickTime)),
        ]),
        const SizedBox(height: 16),
        Field('Tell us what happened *', 'Write a short description...',
          maxLines: 4,
          initial: draft.description,
          error: err ? 'Please describe what happened' : null,
          onChanged: (v) {
            draft.description = v;
            if (showError) setState(() {});
          }),
      ]),
    );
  }

  Widget _photoBtn(IconData i, String t, bool camera) => Expanded(
    child: GestureDetector(
      onTap: () => _addPhotos(camera),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: C.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: C.border),
        ),
        child: Column(children: [
          Icon(i, size: 22, color: C.cream),
          const SizedBox(height: 4),
          Text(t, style: const TextStyle(fontSize: 11)),
        ]),
      ),
    ),
  );

  Future<void> _pickDate() async {
    final init = DateTime.tryParse(draft.date) ?? DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: init,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (d != null) {
      setState(() {
        draft.date = '${d.year}-${two(d.month)}-${two(d.day)}';
        draft.whenEdited = true;
      });
    }
  }

  Future<void> _pickTime() async {
    final parts = draft.time.split(':');
    final init = TimeOfDay(
      hour: int.tryParse(parts.first) ?? 9,
      minute: parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0);
    final t = await showTimePicker(context: context, initialTime: init);
    if (t != null) {
      setState(() {
        draft.time = '${two(t.hour)}:${two(t.minute)}';
        draft.whenEdited = true;
      });
    }
  }

  Widget _pick(String label, String value, IconData i, VoidCallback onTap) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: TextStyle(fontSize: 12, color: C.muted)),
      const SizedBox(height: 6),
      GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            color: C.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: C.border),
          ),
          child: Row(children: [
            Expanded(child: Text(value, style: const TextStyle(fontSize: 13))),
            Icon(i, size: 16, color: C.muted),
          ]),
        ),
      ),
    ],
  );
}

class Step5 extends StatelessWidget {
  const Step5({super.key});

  @override
  Widget build(BuildContext context) {
    final v = draft.noVehicles
        ? 'No vehicles'
        : (draft.vehicles.isEmpty ? '—' : draft.vehicles.join(', '));
    return StepScaffold(
      step: 5,
      title: 'Review your report',
      buttonLabel: 'Send report',
      onNext: () => submitDraft(context),
      body: Column(children: [
        _sec(context, 'What happened', 4, [
          ['Type', draft.type ?? '—'],
          ['Injury status', draft.injury ?? '—'],
          if (draft.injury == 'Injuries' || draft.injury == 'Fatalities') ...[
            ['Injured', '${draft.injuries}'],
            ['Died', '${draft.fatalities}'],
          ],
          ['Severity', draft.severity ?? 'Not set'],
          ['Vehicles', v],
        ]),
        const SizedBox(height: 10),
        _sec(context, 'Where and when', 2, [
          ['Place', draft.place.isEmpty ? 'Current location' : draft.place],
          ['When', '${draft.date} · ${draft.time}'],
        ]),
        const SizedBox(height: 10),
        _sec(context, 'Photos and story', 1, [
          ['Title', draft.title],
          ['Photos', '${draft.photos.length} attached'],
          ['Story', draft.description],
        ]),
      ]),
    );
  }

  Widget _sec(BuildContext c, String title, int back, List<List<String>> rows) => Card1(
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(
          child: Text(title,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13))),
        GestureDetector(
          onTap: () {
            var n = 0;
            Navigator.of(c).popUntil((_) => n++ >= back);
          },
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Text('Edit',
              style: TextStyle(
                color: C.cream, fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ),
      ]),
      const SizedBox(height: 8),
      for (final r in rows)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 70,
              child: Text(r[0], style: TextStyle(color: C.muted, fontSize: 11))),
            Expanded(child: Text(r[1], style: const TextStyle(fontSize: 12))),
          ]),
        ),
    ]),
  );
}

class SentScreen extends StatelessWidget {
  final String id;

  const SentScreen(this.id, {super.key});

  void _viewStatus(BuildContext context) {
    Navigator.pushAndRemoveUntil(context,
      MaterialPageRoute(builder: (_) => const Shell(initialIndex: 1)), (_) => false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: C.green.withValues(alpha: .15),
              border: Border.all(color: C.green, width: 2)),
            child: Icon(Icons.check, color: C.green, size: 36),
          ),
          const SizedBox(height: 18),
          const Text('Report sent',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text('Share this ID so we can find your report.',
            textAlign: TextAlign.center,
            style: TextStyle(color: C.muted, fontSize: 12)),
          const SizedBox(height: 18),
          Card1(
            onTap: () {
              Clipboard.setData(ClipboardData(text: id));
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('Report ID copied')));
            },
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Your report ID',
                style: TextStyle(color: C.muted, fontSize: 11)),
              const SizedBox(height: 4),
              Row(children: [
                Expanded(
                  child: Text(id,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
                Icon(Icons.copy, size: 16, color: C.muted),
              ]),
              const SizedBox(height: 8),
              Tag('Sent', statusColorOf('submitted')),
            ]),
          ),
          const Spacer(),
          PrimaryButton('View report status', () => _viewStatus(context)),
          const SizedBox(height: 8),
          PrimaryButton('Go home', () {
            Navigator.pushAndRemoveUntil(context,
              MaterialPageRoute(builder: (_) => const Shell()), (_) => false);
          }, outlined: true),
        ]),
      ),
    ),
  );
}

class ReportTile extends StatelessWidget {
  final Report r;

  const ReportTile(this.r, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Card1(
      onTap: () => Navigator.push(
        context, MaterialPageRoute(builder: (_) => ReportDetails(r))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(r.id, style: TextStyle(color: C.muted, fontSize: 10))),
          Tag(r.status, statusColor(r.status)),
        ]),
        const SizedBox(height: 6),
        Text(r.title.isEmpty ? r.type : r.title,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
        if (r.title.isNotEmpty)
          Text('${r.type}${r.severity.isEmpty ? '' : ' · ${r.severity}'}',
            style: TextStyle(color: C.muted, fontSize: 11)),
        const SizedBox(height: 4),
        Row(children: [
          Icon(Icons.place_outlined, size: 12, color: C.muted),
          const SizedBox(width: 4),
          Expanded(
            child: Text(r.place,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: C.muted, fontSize: 11))),
        ]),
        const SizedBox(height: 2),
        Row(children: [
          Icon(Icons.calendar_today_outlined, size: 12, color: C.muted),
          const SizedBox(width: 4),
          Text(r.date, style: TextStyle(color: C.muted, fontSize: 11)),
        ]),
      ]),
    ),
  );
}

class MapTab extends StatefulWidget {
  const MapTab({super.key});

  @override
  State<MapTab> createState() => _MapTabState();
}

class _MapTabState extends State<MapTab> {
  final MapController _map = MapController();
  LatLng? _me;
  Report? _picked;
  bool _locating = false;
  String? _msg;

  Future<void> _locate() async {
    setState(() { _locating = true; _msg = null; });
    try {
      final p = await getGpsPosition();
      final me = LatLng(p.latitude, p.longitude);
      if (!mounted) return;
      setState(() => _me = me);
      _map.move(me, 16);
    } catch (e) {
      if (mounted) {
        setState(() => _msg = '$e'.contains('TimeoutException')
            ? 'Could not get a GPS signal. Try again near a window or outside.'
            : '$e');
      }
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  void _fitAll(List<LatLng> pts) {
    if (pts.isEmpty) return;
    if (pts.length == 1) {
      _map.move(pts.first, 15);
      return;
    }
    _map.fitCamera(CameraFit.coordinates(
        coordinates: pts, padding: const EdgeInsets.all(60), maxZoom: 16));
  }

  Widget _fab(IconData icon, VoidCallback onTap) => GestureDetector(
    onTap: onTap,
    child: Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: C.surface, shape: BoxShape.circle, border: Border.all(color: C.border)),
      child: Icon(icon, size: 20, color: C.cream),
    ),
  );

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<List<Report>>(
    valueListenable: reports,
    builder: (_, list, _) {
      final withPin = [for (final r in list) if (r.lat != null && r.lng != null) r];
      final pts = [for (final r in withPin) LatLng(r.lat!, r.lng!)];
      return Stack(children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: pts.isNotEmpty ? pts.first : const LatLng(14.5995, 120.9842),
            initialZoom: pts.isEmpty ? 11 : 15,
            interactionOptions: InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
            onTap: (_, _) => setState(() => _picked = null),
          ),
          children: [
            appTileLayer(),
            MarkerLayer(markers: [
              for (final r in withPin)
                Marker(
                  point: LatLng(r.lat!, r.lng!),
                  width: 40,
                  height: 40,
                  alignment: Alignment.topCenter,
                  child: GestureDetector(
                    onTap: () => setState(() => _picked = r),
                    child: Icon(Icons.location_on, size: 40, color: statusColor(r.status)),
                  ),
                ),
              if (_me != null)
                Marker(
                  point: _me!,
                  width: 22,
                  height: 22,
                  child: Container(
                    decoration: BoxDecoration(
                      color: C.blue,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 3)),
                  ),
                ),
            ]),
            const SimpleAttributionWidget(
                source: Text('Mapbox, OpenStreetMap contributors')),
          ],
        ),
        Positioned(
          top: 12,
          left: 12,
          right: 12,
          child: Card1(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(children: [
              Icon(Icons.map_outlined, size: 18, color: C.cream),
              const SizedBox(width: 8),
              Expanded(
                child: Text(_msg ?? '${withPin.length} of your reports on the map',
                  style: TextStyle(fontSize: 12, color: _msg != null ? C.red : C.text))),
            ]),
          ),
        ),
        Positioned(
          right: 12,
          bottom: _picked == null ? 16 : 150,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            _fab(Icons.zoom_out_map, () => _fitAll(pts)),
            const SizedBox(height: 8),
            _fab(_locating ? Icons.hourglass_top : Icons.my_location,
                _locating ? () {} : _locate),
          ]),
        ),
        if (_picked != null)
          Positioned(left: 12, right: 12, bottom: 12, child: ReportTile(_picked!)),
      ]);
    },
  );
}

class MyReportsTab extends StatefulWidget {
  const MyReportsTab({super.key});

  @override
  State<MyReportsTab> createState() => _MyReportsTabState();
}

class _MyReportsTabState extends State<MyReportsTab> {
  String filter = 'All';

  @override
  Widget build(BuildContext context) {
    const filters = ['All','Sent','Reviewing','Needs info','Verified','Assigned','In progress','Resolved','Rejected'];
    return RefreshIndicator(onRefresh: refreshAll, child: ListView(padding: const EdgeInsets.all(18), children: [
      const Text('My Reports', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
      const SizedBox(height: 12),
      SizedBox(
        height: 32,
        child: ListView(scrollDirection: Axis.horizontal, children: [
          for (final f in filters)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: GestureDetector(
                onTap: () => setState(() => filter = f),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: filter == f ? C.cream : C.surface,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: C.border),
                  ),
                  child: Text(f,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: filter == f ? C.bg : C.text)),
                ),
              ),
            ),
        ]),
      ),
      const SizedBox(height: 14),
      ValueListenableBuilder<List<Report>>(
        valueListenable: reports,
        builder: (_, list, _) {
          final shown =
              list.where((r) => filter == 'All' || r.status == filter).toList();
          if (shown.isEmpty) {
            return Padding(
              padding: const EdgeInsets.only(top: 40),
              child: Center(
                child: Text('No reports here yet.',
                  style: TextStyle(color: C.muted, fontSize: 12))),
            );
          }
          return Column(children: [for (final r in shown) ReportTile(r)]);
        },
      ),
    ]));
  }
}

class AlertsTab extends StatelessWidget {
  const AlertsTab({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<List<AlertItem>>(
    valueListenable: alerts,
    builder: (_, list, _) => RefreshIndicator(onRefresh: refreshAll, child: ListView(padding: const EdgeInsets.all(18), children: [
      Row(children: [
        const Expanded(
          child: Text('Alerts',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800))),
        if (list.any((a) => a.unread))
          GestureDetector(
            onTap: () {
              for (final a in list) {
                a.unread = false;
              }
              alerts.value = List.of(list);
              Api.markAllRead().catchError((_) {});
            },
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Text('Mark all as read',
                style: TextStyle(
                  color: C.cream, fontSize: 12, fontWeight: FontWeight.w600)),
            ),
          ),
      ]),
      const SizedBox(height: 14),
      if (list.isEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 40),
          child: Center(
            child: Text('No alerts yet.',
              style: TextStyle(color: C.muted, fontSize: 12))),
        ),
      for (final a in list)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Card1(
            onTap: () {
              if (a.unread) {
                a.unread = false;
                alerts.value = List.of(list);
                if (a.dbId != null) Api.markRead(a.dbId!).catchError((_) {});
              }
              final r = findReport(a.reportId);
              if (r != null) {
                Navigator.push(
                  context, MaterialPageRoute(builder: (_) => ReportDetails(r)));
              }
            },
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: statusColor(a.status).withValues(alpha: .15)),
                child: Icon(Icons.notifications_none,
                  size: 14, color: statusColor(a.status)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(a.title,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                  const SizedBox(height: 2),
                  Text(a.body, style: TextStyle(color: C.muted, fontSize: 11)),
                ])),
              if (a.unread)
                Container(
                  width: 8,
                  height: 8,
                  margin: const EdgeInsets.only(top: 4),
                  decoration: BoxDecoration(color: C.orange, shape: BoxShape.circle))
              else
                Icon(Icons.chevron_right, size: 16, color: C.muted),
            ]),
          ),
        ),
    ])),
  );
}

class ReportDetails extends StatefulWidget {
  final Report r;

  const ReportDetails(this.r, {super.key});

  @override
  State<ReportDetails> createState() => _ReportDetailsState();
}

class _ReportDetailsState extends State<ReportDetails> with WidgetsBindingObserver {
  Map<String, dynamic>? full; // galing sa GET /reports/:id (kasama ang evidence at status_history)
  String? err;
  Timer? _poll;
  bool _loading = false;
  String _sig = '';

  Report get r => widget.r;
  Map<String, dynamic> get j => full ?? r.raw;
  String s(String k) => txt(j[k]);
  String get _status => s('status').isEmpty ? r.statusKey : s('status');
  bool get _canEdit => full != null && (_status == 'submitted' || _status == 'needs_clarification');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    // Live update: kinukuha ang pinakabagong detalye kada 5 segundo habang nakabukas ang pahina
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => _load());
  }

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load({bool force = false}) async {
    final id = r.dbId;
    if (id == null || Api.token == null) return;
    if (_loading && !force) return; // huwag magpatung-patong kung mabagal ang server
    _loading = true;
    try {
      final data = await Api.reportFull(id);
      if (!mounted) return;
      final sig = jsonEncode(data);
      if (sig != _sig) {
        setState(() { full = data; _sig = sig; err = null; });
        // Sabay ding mag-update ang Dashboard/Reports/Alerts kapag nagbago ang status
        if (findReport(r.id)?.statusKey != txt(data['status'])) {
          refreshAll().catchError((_) {});
        }
      } else if (err != null) {
        setState(() => err = null);
      }
    } catch (e) {
      if (mounted && full == null) {
        setState(() => err = e is ApiException ? e.message : 'Could not load the latest details.');
      }
    } finally {
      _loading = false;
    }
  }

  Future<void> _edit({bool needsInfo = false}) async {
    final f = full;
    if (f == null) return;
    final saved = await Navigator.push<bool>(context, MaterialPageRoute(
      builder: (_) => EditReportScreen(f, needsInfo: needsInfo,
        request: needsInfo ? _latestReason('needs_clarification') : '')));
    if (saved == true) await _load(force: true);
  }

  // Status history galing server (pinakabago muna). Walang "submitted" row ang server para
  // sa bagong report, kaya idinadagdag ito mula sa created_at.
  List<Map<String, dynamic>> get _history {
    if (full == null) return const [];
    final raw = (full!['status_history'] as List?) ?? const [];
    final list = [for (final h in raw) Map<String, dynamic>.from(h as Map)];
    if (!list.any((h) => '${h['new_status']}' == 'submitted') && parseStamp(full!['created_at']) != null) {
      list.add({
        'id': 'created',
        'old_status': null,
        'new_status': 'submitted',
        'reason': null,
        'changed_by_name': user.value.name,
        'changed_at': full!['created_at'],
      });
    }
    return list;
  }

  // Pinakabagong dahilan/remarks para sa isang status (hal. bakit "Needs info" o "Rejected")
  String _latestReason(String status) {
    for (final h in _history) {
      if ('${h['new_status']}' == status) {
        final t = txt(h['reason']);
        if (t.isNotEmpty) return t;
      }
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    final hist = _history;
    final sevKey = s('severity');
    final title = s('title').isEmpty ? (s('category_name').isEmpty ? r.type : s('category_name')) : s('title');
    final verified = s('verified_by').isNotEmpty;
    final category = s('category_name').isEmpty ? 'Uncategorized' : s('category_name');
    final time = prettyTime(s('accident_time'));
    final date = prettyDate(s('accident_date'));
    final vehicles = int.tryParse(s('vehicles_involved')) ?? 0;
    final injured = int.tryParse(s('injuries')) ?? 0;
    final dead = int.tryParse(s('fatalities')) ?? 0;
    final evidence = full == null
        ? null
        : [for (final e in ((full!['evidence'] as List?) ?? const [])) Map<String, dynamic>.from(e as Map)];
    final vNotes = s('verification_notes');
    final vType = s('vehicle_type');
    final vehicleText = (vType.isEmpty || vType == 'None')
        ? (vehicles == 0 ? 'No vehicles involved' : '$vehicles')
        : '$vType ($vehicles)';
    final contact = [user.value.mobile, s('reporter_email')].where((x) => x.isNotEmpty).join(' · ');
    final officer = s('assigned_officer_name').isNotEmpty
        ? s('assigned_officer_name')
        : s('assigned_to').isNotEmpty ? 'A traffic officer is assigned' : 'Not yet assigned';
    final findings = s('findings');
    final rejectReason = _latestReason('rejected').isNotEmpty ? _latestReason('rejected') : s('verification_notes');
    final lat = double.tryParse(s('latitude'));
    final lng = double.tryParse(s('longitude'));
    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => _load(force: true),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(18),
            children: [
              Row(children: [
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.arrow_back_ios_new, size: 16)),
                const Expanded(
                  child: Text('Report details',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15))),
                if (_canEdit)
                  GestureDetector(
                    onTap: () => _edit(),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: C.border)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.edit_outlined, size: 14, color: C.cream),
                        const SizedBox(width: 6),
                        Text('Edit report',
                          style: TextStyle(color: C.cream, fontSize: 12, fontWeight: FontWeight.w700)),
                      ]),
                    ),
                  ),
              ]),
              const SizedBox(height: 6),
              Text('${r.id} · Reported ${timeAgo(j['created_at'])}',
                style: TextStyle(color: C.muted, fontSize: 11)),
              const SizedBox(height: 4),
              Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
              if (s('location').isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(s('location'), style: TextStyle(color: C.muted, fontSize: 13)),
                ),
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 6, children: [
                Tag(kStatusLabel[status] ?? 'Sent', statusColorOf(status)),
                Tag(kSeverityLabel[sevKey] ?? 'Unclassified', severityColor(sevKey)),
              ]),
              const SizedBox(height: 8),
              _recordBadge(verified, prettyDate(s('verified_at'))),
              if (err != null && full == null) ...[
                const SizedBox(height: 12),
                Card1(
                  onTap: () => _load(force: true),
                  child: Row(children: [
                    Icon(Icons.error_outline, size: 18, color: C.red),
                    const SizedBox(width: 10),
                    Expanded(child: Text('$err Tap to retry.',
                      style: TextStyle(color: C.muted, fontSize: 12))),
                  ]),
                ),
              ],
              if (status == 'needs_clarification') ...[
                const SizedBox(height: 14),
                _banner(
                  statusColorOf(status),
                  'Staff need more information',
                  _latestReason(status).isEmpty
                      ? 'Please review your report and add the missing details.'
                      : _latestReason(status),
                  action: _canEdit
                      ? PrimaryButton('Update report and send back', () => _edit(needsInfo: true))
                      : null),
              ],
              if (status == 'rejected') ...[
                const SizedBox(height: 14),
                _banner(
                  statusColorOf(status),
                  'This report was rejected',
                  rejectReason.isEmpty ? 'No reason was given.' : rejectReason),
              ],
              const SizedBox(height: 14),
              _PhotosCard(id: r.dbId, items: evidence),
              const SizedBox(height: 10),
              Card1(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: _tile('$vehicles', 'Vehicles')),
                    const SizedBox(width: 8),
                    Expanded(child: _tile('$injured', 'Injured')),
                    const SizedBox(width: 8),
                    Expanded(child: _tile('$dead', 'Fatalities')),
                  ]),
                  const SizedBox(height: 16),
                  const Text('What happened', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Text(s('description').isEmpty ? 'No description was provided.' : s('description'),
                    style: TextStyle(color: C.muted, fontSize: 12.5, height: 1.5)),
                ]),
              ),
              const SizedBox(height: 10),
              Card1(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Details', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  _row('Report ID', r.id),
                  _row('Reported by', s('reporter_name').isEmpty ? user.value.name : s('reporter_name')),
                  _row('Contact', contact.isEmpty ? 'Not provided' : contact),
                  _row('Date of accident', date),
                  _row('Time of accident', time.isEmpty ? 'Not stated' : time),
                  _row('Accident type', category),
                  _row('Vehicles involved', vehicleText),
                  _row('Injury status', kInjuryLabel[s('injury_status')] ?? 'Unknown'),
                  _row('Severity', kSeverityLabel[sevKey] ?? 'Not set'),
                  _row('Report status', kStatusLabel[status] ?? 'Sent'),
                  _row('Date submitted', stampLabel(j['created_at'])),
                  _row('Assigned officer', officer),
                  if (s('duplicate_of_reference').isNotEmpty)
                    _row('Same accident as', s('duplicate_of_reference')),
                  if (verified && s('verified_at').isNotEmpty)
                    _row('Verified on', stampLabel(j['verified_at'])),
                ]),
              ),
              const SizedBox(height: 10),
              Card1(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Official remarks', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  if (vNotes.isEmpty && findings.isEmpty)
                    Text('No remarks from staff yet.', style: TextStyle(color: C.muted, fontSize: 12)),
                  if (vNotes.isNotEmpty)
                    _note(status == 'rejected' ? 'Reason for rejection' : 'Verification notes', vNotes),
                  if (findings.isNotEmpty) _note('Officer findings', findings),
                ]),
              ),
              const SizedBox(height: 10),
              Card1(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('History', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 12),
                  if (full == null)
                    Text(err == null ? 'Loading history...' : 'History is not available right now.',
                      style: TextStyle(color: C.muted, fontSize: 12))
                  else if (hist.isEmpty)
                    Text('No status changes yet.', style: TextStyle(color: C.muted, fontSize: 12))
                  else
                    for (var i = 0; i < hist.length; i++) _timelineRow(hist[i], last: i == hist.length - 1),
                ]),
              ),
              const SizedBox(height: 10),
              Card1(
                onTap: () => Navigator.push(
                  context, MaterialPageRoute(builder: (_) => PlaceViewScreen(s('location'), lat: lat, lng: lng))),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Location', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 10),
                  if (lat != null && lng != null)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: SizedBox(
                        height: 150,
                        child: IgnorePointer(
                          child: FlutterMap(
                            options: MapOptions(
                              initialCenter: LatLng(lat, lng),
                              initialZoom: 15,
                              interactionOptions: const InteractionOptions(flags: InteractiveFlag.none)),
                            children: [
                              appTileLayer(),
                              MarkerLayer(markers: [
                                Marker(
                                  point: LatLng(lat, lng),
                                  width: 36,
                                  height: 36,
                                  alignment: Alignment.topCenter,
                                  child: Icon(Icons.location_on, size: 36, color: statusColorOf(status))),
                              ]),
                            ],
                          ),
                        ),
                      ),
                    )
                  else
                    Text('This report has no map coordinates.',
                      style: TextStyle(color: C.muted, fontSize: 12)),
                  const SizedBox(height: 8),
                  Text(s('location'), style: const TextStyle(fontSize: 13)),
                  if (lat != null && lng != null)
                    Text('${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}',
                      style: TextStyle(color: C.muted, fontSize: 11)),
                ]),
              ),
              if (r.status == 'Draft') ...[
                const SizedBox(height: 16),
                PrimaryButton('Continue draft', () {
                  draft.type = r.type;
                  draft.injury = r.injury;
                  draft.vehicles.clear();
                  draft.noVehicles = false;
                  draft.total = 1;
                  draft.place = r.place;
                  draft.description = r.description;
                  draft.pinMode = false;
                  draft.lat = r.lat;
                  draft.lng = r.lng;
                  draft.draftId = r.id;
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const Step1()));
                }),
                const SizedBox(height: 8),
                PrimaryButton('Delete draft', () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      backgroundColor: C.surface,
                      title: Text('Delete draft?',
                        style: TextStyle(
                          color: C.text, fontWeight: FontWeight.w800, fontSize: 18)),
                      content: Text('This draft will be removed.',
                        style: TextStyle(color: C.muted, fontSize: 13)),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: Text('Cancel', style: TextStyle(color: C.muted)),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: Text('Delete',
                            style: TextStyle(color: C.red, fontWeight: FontWeight.w700)),
                        ),
                      ],
                    ),
                  );
                  if (ok == true && context.mounted) {
                    reports.value = reports.value.where((x) => x.id != r.id).toList();
                    Navigator.pop(context);
                  }
                }, outlined: true),
              ],
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  // Malinaw na pagkakaiba ng public report at opisyal na verified record
  Widget _recordBadge(bool verified, String when) {
    final tone = verified ? C.green : C.muted;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: .1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: tone.withValues(alpha: .4)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(verified ? Icons.verified_outlined : Icons.public, size: 18, color: tone),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(verified ? 'Officially verified record' : 'Public report, not yet verified',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5, color: verified ? tone : C.text)),
            const SizedBox(height: 2),
            Text(
              verified
                  ? 'Verified by staff on $when. This is an official record.'
                  : 'Submitted by a member of the public. It is not an official record until staff verify it.',
              style: TextStyle(color: C.muted, fontSize: 11, height: 1.4)),
          ]),
        ),
      ]),
    );
  }

  Widget _banner(Color tone, String title, String body, {Widget? action}) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: tone.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: tone.withValues(alpha: .5)),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: tone)),
      const SizedBox(height: 4),
      Text(body, style: const TextStyle(fontSize: 12.5, height: 1.45)),
      if (action != null) ...[const SizedBox(height: 12), action],
    ]),
  );

  Widget _tile(String value, String label) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    decoration: BoxDecoration(color: C.surface2, borderRadius: BorderRadius.circular(12)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
      const SizedBox(height: 2),
      Text(label, style: TextStyle(color: C.muted, fontSize: 11)),
    ]),
  );

  Widget _note(String label, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: TextStyle(color: C.muted, fontSize: 11)),
      const SizedBox(height: 3),
      Text(text, style: const TextStyle(fontSize: 12.5, height: 1.45)),
    ]),
  );

  // Isang hakbang sa totoong status history (kulay, "from ...", remarks, sino at kailan)
  Widget _timelineRow(Map<String, dynamic> h, {required bool last}) {
    final ns = txt(h['new_status']);
    final os = txt(h['old_status']);
    final reason = txt(h['reason']);
    final who = txt(h['changed_by_name']);
    final when = stampLabel(h['changed_at']);
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          width: 14,
          child: Column(children: [
            Container(
              margin: const EdgeInsets.only(top: 3),
              width: 14,
              height: 14,
              decoration: BoxDecoration(color: statusColorOf(ns), shape: BoxShape.circle)),
            if (!last) Expanded(child: Container(width: 2, color: C.border)),
          ]),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(bottom: last ? 0 : 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text.rich(TextSpan(children: [
                TextSpan(
                  text: kStatusLabel[ns] ?? ns,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                if (os.isNotEmpty)
                  TextSpan(
                    text: ' from ${(kStatusLabel[os] ?? os).toLowerCase()}',
                    style: TextStyle(color: C.muted, fontSize: 12)),
              ])),
              if (reason.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(reason, style: const TextStyle(fontSize: 12.5, height: 1.4)),
                ),
              const SizedBox(height: 3),
              Text([who, when].where((x) => x.isNotEmpty).join(' · '),
                style: TextStyle(color: C.muted, fontSize: 10)),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _row(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(k, style: TextStyle(color: C.muted, fontSize: 11)),
      const SizedBox(width: 12),
      Expanded(child: Text(v, textAlign: TextAlign.right, style: const TextStyle(fontSize: 12))),
    ]),
  );
}

// I-edit ang sariling report (puwede lang kapag Sent o Needs info), kapareho ng web.
// Kapag "Needs info" at na-save, ibinabalik ng server ang report sa Reviewing.
class EditReportScreen extends StatefulWidget {
  final Map<String, dynamic> report;
  final bool needsInfo;
  final String request; // ang hinihingi ng staff (para sa Needs info)

  const EditReportScreen(this.report, {super.key, this.needsInfo = false, this.request = ''});

  @override
  State<EditReportScreen> createState() => _EditReportScreenState();
}

class _EditReportScreenState extends State<EditReportScreen> {
  static const int _maxPhotos = 5;
  final ImagePicker _picker = ImagePicker();
  late final TextEditingController _title, _desc, _place, _vehicleType;
  List<Map<String, dynamic>> _cats = [];
  int? _catId;
  late String _injury;
  String? _severity;
  late int _injured, _dead, _vehicles;
  late String _date, _time;
  double? _lat, _lng;
  final List<Photo> _photos = [];
  bool _saving = false, _locating = false;
  String? _photoMsg, _formMsg;
  final Map<String, String> _errs = {};

  Map<String, dynamic> get _r => widget.report;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: txt(_r['title']));
    _desc = TextEditingController(text: txt(_r['description']));
    _place = TextEditingController(text: txt(_r['location']));
    final vt = txt(_r['vehicle_type']);
    _vehicleType = TextEditingController(text: vt == 'None' ? '' : vt);
    _catId = int.tryParse(txt(_r['accident_category_id']));
    final inj = txt(_r['injury_status']);
    _injury = kInjuryLabel.containsKey(inj) ? inj : 'unknown';
    final sev = txt(_r['severity']);
    _severity = kSeverityLabel.containsKey(sev) ? sev : null;
    _injured = int.tryParse(txt(_r['injuries'])) ?? 0;
    _dead = int.tryParse(txt(_r['fatalities'])) ?? 0;
    _vehicles = int.tryParse(txt(_r['vehicles_involved'])) ?? 0;
    final d = txt(_r['accident_date']);
    _date = d.length >= 10 ? d.substring(0, 10) : todayIso();
    final t = txt(_r['accident_time']);
    _time = t.length >= 5 ? t.substring(0, 5) : nowHm();
    _lat = double.tryParse(txt(_r['latitude']));
    _lng = double.tryParse(txt(_r['longitude']));
    Api.categories().then((c) {
      if (mounted) setState(() => _cats = c);
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _title.dispose();
    _desc.dispose();
    _place.dispose();
    _vehicleType.dispose();
    super.dispose();
  }

  Future<void> _addPhotos(bool camera) async {
    if (_photos.length >= _maxPhotos) {
      setState(() => _photoMsg = 'You can add up to $_maxPhotos photos at a time.');
      return;
    }
    try {
      List<XFile> files = [];
      if (camera) {
        final x = await _picker.pickImage(
            source: ImageSource.camera, imageQuality: 80, maxWidth: 1600);
        if (x != null) files = [x];
      } else {
        files = await _picker.pickMultiImage(imageQuality: 80, maxWidth: 1600);
      }
      var skipped = 0;
      for (final f in files) {
        if (_photos.length >= _maxPhotos) {
          skipped++;
          continue;
        }
        final bytes = await f.readAsBytes();
        if (bytes.length > 10 * 1024 * 1024 || Api.sniffMime(bytes) == null) {
          skipped++;
          continue;
        }
        _photos.add(Photo(f.name, bytes));
      }
      if (mounted) {
        setState(() => _photoMsg = skipped > 0
            ? '$skipped photo(s) skipped (max $_maxPhotos, JPG/PNG/WebP, under 10 MB).'
            : null);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _photoMsg = 'Could not open the camera or gallery. Check the app permissions.');
      }
    }
  }

  Future<void> _useMyLocation() async {
    setState(() { _locating = true; _formMsg = null; });
    try {
      final p = await getGpsPosition();
      _lat = p.latitude;
      _lng = p.longitude;
      // Hanapin ang pangalan ng kalsada (OpenStreetMap). Tahimik kung walang internet.
      try {
        final res = await http.get(
          Uri.parse('https://nominatim.openstreetmap.org/reverse?format=jsonv2'
              '&lat=${p.latitude}&lon=${p.longitude}&zoom=18'),
          headers: {'User-Agent': kPackageName, 'Accept-Language': 'en'},
        ).timeout(const Duration(seconds: 8));
        if (res.statusCode == 200) {
          final name = txt((jsonDecode(res.body) as Map)['display_name']);
          if (name.isNotEmpty) _place.text = name;
        }
      } catch (_) {}
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        setState(() => _formMsg = '$e'.contains('TimeoutException')
            ? 'Could not get a GPS signal. Try again near a window or outside.'
            : '$e');
      }
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(_date) ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (d != null) setState(() => _date = '${d.year}-${two(d.month)}-${two(d.day)}');
  }

  Future<void> _pickTime() async {
    final parts = _time.split(':');
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: int.tryParse(parts.first) ?? 9,
        minute: parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0),
    );
    if (t != null) setState(() => _time = '${two(t.hour)}:${two(t.minute)}');
  }

  Future<void> _save() async {
    if (_saving) return;
    final errs = <String, String>{};
    if (_title.text.trim().length < 3) errs['title'] = 'Title is required';
    if (_desc.text.trim().isEmpty) errs['description'] = 'Please describe what happened';
    if (_place.text.trim().isEmpty) errs['location'] = 'Location is required';
    if (_catId == null) errs['category'] = 'Pick what happened';
    final when = DateTime.tryParse('$_date $_time');
    if (when != null && when.isAfter(DateTime.now().add(const Duration(minutes: 1)))) {
      errs['when'] = 'The date and time cannot be in the future.';
    }
    final id = int.tryParse(txt(_r['id']));
    if (id == null) errs['id'] = 'This report cannot be edited.';
    if (errs.isNotEmpty) {
      setState(() {
        _errs
          ..clear()
          ..addAll(errs);
        _formMsg = errs['id'] ?? 'Please fix the highlighted fields.';
      });
      return;
    }
    final rid = id!;
    setState(() { _saving = true; _errs.clear(); _formMsg = null; });
    final msg = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    final counts = _injury == 'injuries' || _injury == 'fatalities';
    final vt = _vehicleType.text.trim();
    try {
      await Api.updateReport(rid, {
        'title': _title.text.trim(),
        'description': _desc.text.trim(),
        'location': _place.text.trim(),
        'accident_category_id': _catId,
        'accident_date': _date,
        'accident_time': _time,
        'injury_status': _injury,
        'injuries': counts ? _injured : 0,
        'fatalities': counts ? _dead : 0,
        'severity': _severity,
        'vehicles_involved': _vehicles,
        'vehicle_type': vt.isEmpty ? (_vehicles == 0 ? 'None' : null) : vt,
        if (_lat != null && _lng != null) ...{
          'latitude': double.parse(_lat!.toStringAsFixed(6)),
          'longitude': double.parse(_lng!.toStringAsFixed(6)),
        },
      });
    } on ApiException catch (e) {
      if (mounted) setState(() { _saving = false; _formMsg = e.message; });
      return;
    } catch (_) {
      if (mounted) setState(() { _saving = false; _formMsg = 'Something went wrong. Try again.'; });
      return;
    }
    // Na-save na ang report; isa-isang i-upload ang bagong larawan
    var failed = 0;
    for (final p in List<Photo>.of(_photos)) {
      try {
        await Api.uploadEvidence(rid, p);
      } catch (_) {
        failed++;
      }
    }
    try { await refreshAll(); } catch (_) {}
    msg.showSnackBar(SnackBar(
        content: Text(failed > 0
            ? 'Saved, but $failed photo(s) could not be uploaded.'
            : widget.needsInfo ? 'Sent back for review.' : 'Changes saved.')));
    if (mounted) nav.pop(true);
  }

  Widget _label(String t, {bool star = false}) => Text.rich(
    TextSpan(text: t, children: [
      if (star) TextSpan(text: ' *', style: TextStyle(color: C.red)),
    ]),
    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14));

  Widget _err(String? m) => m == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(m, style: TextStyle(color: C.red, fontSize: 11)));

  Widget _pick(String label, String value, IconData i, VoidCallback onTap) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: TextStyle(fontSize: 12, color: C.muted)),
      const SizedBox(height: 6),
      GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            color: C.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _errs.containsKey('when') ? C.red : C.border),
          ),
          child: Row(children: [
            Expanded(child: Text(value, style: const TextStyle(fontSize: 13))),
            Icon(i, size: 16, color: C.muted),
          ]),
        ),
      ),
    ],
  );

  Widget _photoBtn(IconData i, String t, bool camera) => Expanded(
    child: GestureDetector(
      onTap: () => _addPhotos(camera),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: C.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: C.border),
        ),
        child: Column(children: [
          Icon(i, size: 22, color: C.cream),
          const SizedBox(height: 4),
          Text(t, style: const TextStyle(fontSize: 11)),
        ]),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final showCounts = _injury == 'injuries' || _injury == 'fatalities';
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          screenHeader(context, widget.needsInfo ? 'Send more information' : 'Edit report'),
          Expanded(
            child: ListView(padding: const EdgeInsets.all(18), children: [
              if (widget.needsInfo) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: statusColorOf('needs_clarification').withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: statusColorOf('needs_clarification').withValues(alpha: .5)),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Staff asked for more information',
                      style: TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 14,
                        color: statusColorOf('needs_clarification'))),
                    const SizedBox(height: 4),
                    Text(widget.request.isEmpty
                        ? 'Add the missing details below, then send the report back for review.'
                        : widget.request,
                      style: const TextStyle(fontSize: 12.5, height: 1.45)),
                  ]),
                ),
                const SizedBox(height: 16),
              ],
              Field('Title *', 'Short title of the accident',
                controller: _title, error: _errs['title']),
              _label('What happened', star: true),
              _err(_errs['category']),
              const SizedBox(height: 8),
              if (_cats.isEmpty)
                Text('Loading accident types...', style: TextStyle(color: C.muted, fontSize: 12))
              else
                Grid2([
                  for (final c in _cats)
                    OptionCard('${c['name']}', '', _catId == c['id'],
                      () => setState(() => _catId = c['id'] as int)),
                ]),
              const SizedBox(height: 18),
              _label('Injury status', star: true),
              const SizedBox(height: 8),
              Grid2([
                for (final e in kInjuryLabel.entries)
                  OptionCard(e.value, '', _injury == e.key, () => setState(() {
                    _injury = e.key;
                    if (e.key == 'injuries' && _injured == 0) _injured = 1;
                    if (e.key == 'fatalities' && _dead == 0) _dead = 1;
                    if (e.key == 'none' || e.key == 'unknown') {
                      _injured = 0;
                      _dead = 0;
                    }
                  })),
              ]),
              if (showCounts) ...[
                const SizedBox(height: 14),
                CounterRow('People injured', _injured, (v) => setState(() => _injured = v)),
                const SizedBox(height: 10),
                CounterRow('People who died', _dead, (v) => setState(() => _dead = v)),
              ],
              const SizedBox(height: 18),
              _label('Severity'),
              Text('Optional. Tap again to clear.', style: TextStyle(color: C.muted, fontSize: 11)),
              const SizedBox(height: 8),
              Grid2([
                for (final e in kSeverityLabel.entries)
                  OptionCard(e.value, '', _severity == e.key,
                    () => setState(() => _severity = _severity == e.key ? null : e.key)),
              ]),
              const SizedBox(height: 18),
              CounterRow('Vehicles involved', _vehicles, (v) => setState(() => _vehicles = v)),
              const SizedBox(height: 12),
              Field('Vehicle types', 'e.g. Car, Motorcycle', controller: _vehicleType),
              Row(children: [
                Expanded(child: _pick('Date *', _date, Icons.calendar_today_outlined, _pickDate)),
                const SizedBox(width: 8),
                Expanded(child: _pick('Time *', _time, Icons.access_time, _pickTime)),
              ]),
              _err(_errs['when']),
              const SizedBox(height: 16),
              Field('Location *', 'Street, barangay, city',
                controller: _place, error: _errs['location'], maxLines: 2),
              Align(
                alignment: Alignment.centerLeft,
                child: GestureDetector(
                  onTap: _locating ? null : _useMyLocation,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: C.border)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(_locating ? Icons.hourglass_top : Icons.my_location, size: 14, color: C.cream),
                      const SizedBox(width: 6),
                      Text(_locating ? 'Getting location...' : 'Use my current location',
                        style: TextStyle(color: C.cream, fontSize: 12, fontWeight: FontWeight.w700)),
                    ]),
                  ),
                ),
              ),
              if (_lat != null && _lng != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('Pinned at ${_lat!.toStringAsFixed(5)}, ${_lng!.toStringAsFixed(5)}',
                    style: TextStyle(color: C.muted, fontSize: 11)),
                ),
              const SizedBox(height: 16),
              Field('What happened *', 'Write a short description...',
                controller: _desc, maxLines: 5, error: _errs['description']),
              _label('Add photos'),
              Text('Photos already on this report stay. New ones are added to them.',
                style: TextStyle(color: C.muted, fontSize: 11)),
              const SizedBox(height: 8),
              Row(children: [
                _photoBtn(Icons.photo_camera_outlined, 'Take photo', true),
                const SizedBox(width: 8),
                _photoBtn(Icons.photo_library_outlined, 'From gallery', false),
              ]),
              if (_photos.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (var i = 0; i < _photos.length; i++)
                    Stack(children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.memory(_photos[i].bytes, width: 72, height: 72, fit: BoxFit.cover)),
                      Positioned(
                        top: 3,
                        right: 3,
                        child: GestureDetector(
                          onTap: () => setState(() => _photos.removeAt(i)),
                          child: Container(
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              color: C.red, shape: BoxShape.circle,
                              border: Border.all(color: C.bg, width: 2)),
                            child: const Icon(Icons.close, size: 12, color: Colors.white),
                          ),
                        ),
                      ),
                    ]),
                ]),
              ],
              if (_photos.isNotEmpty || _photoMsg != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(_photoMsg ?? '${_photos.length} of $_maxPhotos new photos',
                    style: TextStyle(color: _photoMsg != null ? C.red : C.cream, fontSize: 11)),
                ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 16),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (_formMsg != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(_formMsg!, style: TextStyle(color: C.red, fontSize: 12)),
                ),
              PrimaryButton(
                _saving ? 'Saving...' : widget.needsInfo ? 'Send to review' : 'Save changes',
                _saving ? () {} : _save),
            ]),
          ),
        ]),
      ),
    );
  }
}

class PlaceViewScreen extends StatelessWidget {
  final String place;
  final double? lat, lng;

  const PlaceViewScreen(this.place, {super.key, this.lat, this.lng});

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Column(children: [
        screenHeader(context, 'Location'),
        Expanded(
          child: Container(
            margin: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: C.surface2,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: C.border),
            ),
            child: (lat == null || lng == null)
                ? Center(
                    child: Text('No GPS location saved for this report',
                        style: TextStyle(color: C.muted, fontSize: 12)))
                : ClipRRect(
                    borderRadius: BorderRadius.circular(13),
                    child: FlutterMap(
                      options: MapOptions(
                          initialCenter: LatLng(lat!, lng!), initialZoom: 16),
                      children: [
                        appTileLayer(),
                        MarkerLayer(markers: [
                          Marker(
                            point: LatLng(lat!, lng!),
                            width: 44,
                            height: 44,
                            alignment: Alignment.topCenter,
                            child: Icon(Icons.location_on, size: 44, color: C.red),
                          ),
                        ]),
                      ],
                    ),
                  ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Card1(
            child: Row(children: [
              Icon(Icons.place_outlined, size: 18, color: C.cream),
              const SizedBox(width: 10),
              Expanded(child: Text(place, style: const TextStyle(fontSize: 13))),
            ]),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
          child: PrimaryButton('Back to report', () => Navigator.pop(context)),
        ),
      ]),
    ),
  );
}

// Mga larawan ng report. Galing sa parehong GET /reports/:id kaya nag-a-update kasabay ng pahina.
class _PhotosCard extends StatelessWidget {
  final int? id;
  final List<Map<String, dynamic>>? items; // null = naglo-load pa

  const _PhotosCard({required this.id, required this.items});

  Widget _img(int reportId, int evId, {double? w, double? h}) => Image.network(
    Api.evidenceUrl(reportId, evId),
    headers: Api.authHeaders,
    width: w,
    height: h,
    fit: BoxFit.cover,
    errorBuilder: (_, _, _) => Container(
      width: w,
      height: h,
      color: C.surface2,
      child: Icon(Icons.broken_image_outlined, color: C.muted),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final rid = id;
    final imgs = (items ?? []).where((e) => '${e['mime_type']}'.startsWith('image/')).toList();
    void open(Map<String, dynamic> e) {
      if (rid == null) return;
      Navigator.push(context, MaterialPageRoute(
        builder: (_) => PhotoViewScreen(url: Api.evidenceUrl(rid, e['id'] as int))));
    }
    return Card1(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Photos (${imgs.length})', style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        if (items == null)
          Text('Loading...', style: TextStyle(color: C.muted, fontSize: 12))
        else if (imgs.isEmpty || rid == null)
          Text('No photos attached.', style: TextStyle(color: C.muted, fontSize: 12))
        else ...[
          GestureDetector(
            onTap: () => open(imgs.first),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: AspectRatio(
                aspectRatio: 16 / 10,
                child: _img(rid, imgs.first['id'] as int),
              ),
            ),
          ),
          if (imgs.length > 1) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final e in imgs.skip(1))
                GestureDetector(
                  onTap: () => open(e),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: _img(rid, e['id'] as int, w: 72, h: 72),
                  ),
                ),
            ]),
          ],
        ],
      ]),
    );
  }
}

class PhotoViewScreen extends StatelessWidget {
  final String? url;

  const PhotoViewScreen({super.key, this.url});

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Column(children: [
        screenHeader(context, 'Photo'),
        Expanded(
          child: Center(
            child: url == null
                ? Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.image_outlined, size: 64, color: C.muted),
                    const SizedBox(height: 10),
                    Text('No photo attached', style: TextStyle(color: C.muted, fontSize: 13)),
                  ])
                : InteractiveViewer(
                    child: Image.network(
                      url!,
                      headers: Api.authHeaders,
                      fit: BoxFit.contain,
                      loadingBuilder: (_, child, p) => p == null
                          ? child
                          : const Center(child: CircularProgressIndicator()),
                      errorBuilder: (_, _, _) => Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.broken_image_outlined, size: 64, color: C.muted),
                        const SizedBox(height: 10),
                        Text('Photo is not available on this server',
                            style: TextStyle(color: C.muted, fontSize: 13)),
                      ]),
                    ),
                  ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
          child: PrimaryButton('Back to report', () => Navigator.pop(context)),
        ),
      ]),
    ),
  );
}

class ThemeToggle extends StatelessWidget {
  const ThemeToggle({super.key});

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: C.d ? 'Light mode' : 'Dark mode',
    icon: Icon(C.d ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
      color: C.muted),
    onPressed: () => setDark(!C.d),
  );
}

class ProfileButton extends StatelessWidget {
  final VoidCallback? goReports, goAlerts;

  const ProfileButton({super.key, this.goReports, this.goAlerts});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<UserProfile>(
    valueListenable: user,
    builder: (_, u, _) => IconButton(
      tooltip: 'Profile',
      padding: EdgeInsets.zero,
      icon: Container(
        width: 30,
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: C.surface2,
          border: Border.all(color: C.cream, width: 1.5),
        ),
        child: Text(initialsOf(u.name),
          style: TextStyle(color: C.cream, fontSize: 11, fontWeight: FontWeight.w800)),
      ),
      onPressed: () =>
          showProfileSheet(context, goReports: goReports, goAlerts: goAlerts),
    ),
  );
}

void showProfileSheet(BuildContext context,
  {VoidCallback? goReports, VoidCallback? goAlerts}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: C.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
          child: ValueListenableBuilder<UserProfile>(
            valueListenable: user,
            builder: (_, u, _) => SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 64,
                height: 64,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: C.surface2,
                  border: Border.all(color: C.cream, width: 2),
                ),
                child: Text(initialsOf(u.name),
                  style: TextStyle(color: C.cream, fontSize: 22, fontWeight: FontWeight.w800)),
              ),
              const SizedBox(height: 12),
              Text(u.name,
                style: TextStyle(color: C.text, fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text(u.email, style: TextStyle(color: C.muted, fontSize: 12)),
              const SizedBox(height: 16),
              Card1(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                child: Column(children: [
                  _menuRow(Icons.edit_outlined, 'Edit profile', () {
                    Navigator.pop(ctx);
                    Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const EditProfileScreen()));
                  }),
                  Divider(height: 1, color: C.border),
                  ValueListenableBuilder<List<Report>>(
                    valueListenable: reports,
                    builder: (_, list, _) => _menuRow(
                      Icons.description_outlined, 'My Reports', () {
                        Navigator.pop(ctx);
                        goReports?.call();
                      }, trailing: '${list.length}'),
                  ),
                  Divider(height: 1, color: C.border),
                  ValueListenableBuilder<List<AlertItem>>(
                    valueListenable: alerts,
                    builder: (_, list, _) {
                      final n = list.where((a) => a.unread).length;
                      return _menuRow(Icons.notifications_none, 'Alerts', () {
                        Navigator.pop(ctx);
                        goAlerts?.call();
                      }, trailing: n == 0 ? null : '$n new');
                    },
                  ),
                ]),
              ),
              const SizedBox(height: 16),
              PrimaryButton('Log out', () {
                Navigator.pop(ctx);
                confirmLogout(context);
              }, outlined: true),
            ])),
          ),
        ),
      ),
    );
  }

Widget _menuRow(IconData icon, String label, VoidCallback onTap, {String? trailing}) =>
    GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(children: [
          Icon(icon, size: 18, color: C.cream),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label,
              style: TextStyle(color: C.text, fontSize: 13, fontWeight: FontWeight.w600))),
          if (trailing != null)
            Text(trailing, style: TextStyle(color: C.muted, fontSize: 12)),
          const SizedBox(width: 4),
          Icon(Icons.chevron_right, size: 18, color: C.muted),
        ]),
      ),
    );

class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  String name = user.value.name;
  String mobile = user.value.mobile;
  String email = user.value.email;
  bool submitted = false;

  String? get nameError =>
      submitted && name.trim().isEmpty ? 'Enter your full name' : null;

  String? get mobileError =>
      submitted && mobile.trim().isNotEmpty ? mobileErr(mobile) : null;

  String? get emailError => submitted ? emailErr(email) : null;

  void _save() {
    setState(() => submitted = true);
    if (nameError != null || mobileError != null || emailError != null) return;
    user.value = UserProfile(name.trim(), mobile.trim(), email.trim());
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Profile updated')));
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      backgroundColor: C.bg,
      elevation: 0,
      title: const Text('Edit profile', style: TextStyle(fontSize: 15)),
    ),
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(children: [
          Field('Full name', 'Juan Dela Cruz',
            initial: name,
            error: nameError,
            onChanged: (v) => setState(() => name = v)),
          Field('Mobile number', '09xx xxx xxxx',
            initial: mobile,
            error: mobileError,
            onChanged: (v) => setState(() => mobile = v)),
          Field('Email', 'name@email.com',
            initial: email,
            error: emailError,
            onChanged: (v) => setState(() => email = v)),
          const SizedBox(height: 10),
          PrimaryButton('Save changes', _save),
          const SizedBox(height: 10),
          PrimaryButton('Cancel', () => Navigator.pop(context), outlined: true),
        ]),
      ),
    ),
  );
}

Future<void> confirmLogout(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: C.surface,
      title: Text('Log out?',
        style: TextStyle(
          color: C.text, fontWeight: FontWeight.w800, fontSize: 18)),
      content: Text('You will need to log in again to see your reports.',
        style: TextStyle(color: C.muted, fontSize: 13)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text('Cancel', style: TextStyle(color: C.muted)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text('Log out',
            style: TextStyle(color: C.red, fontWeight: FontWeight.w700)),
        ),
      ],
    ),
  );
  if (ok == true && context.mounted) {
    final nav = Navigator.of(context);
    await Api.logout();
    nav.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()), (_) => false);
  }
}

class AgapLogo extends StatelessWidget {
  final double width;

  const AgapLogo({super.key, this.width = 200});

  @override
  Widget build(BuildContext context) => Image.memory(_logoBytes,
    width: width, height: width * 140 / 400, fit: BoxFit.contain,
    color: C.cream, colorBlendMode: BlendMode.srcIn, gaplessPlayback: true);
}

final Uint8List _logoBytes = base64Decode(_logoB64);

const String _logoB64 = "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";
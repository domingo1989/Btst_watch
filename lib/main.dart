import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  runApp(const BTSTApp());
}

class BTSTApp extends StatelessWidget {
  const BTSTApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Surveillance BTST',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const ZoneSelectionPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class ZoneSelectionPage extends StatefulWidget {
  const ZoneSelectionPage({super.key});

  @override
  State<ZoneSelectionPage> createState() => _ZoneSelectionPageState();
}

class _ZoneSelectionPageState extends State<ZoneSelectionPage> {
  final _latMinController = TextEditingController(text: "5.4");
  final _latMaxController = TextEditingController(text: "14.0");
  final _lonMinController = TextEditingController(text: "3.5");
  final _lonMaxController = TextEditingController(text: "15.0");

  void _demarrerSurveillance() {
    final double? latMin = double.tryParse(_latMinController.text);
    final double? latMax = double.tryParse(_latMaxController.text);
    final double? lonMin = double.tryParse(_lonMinController.text);
    final double? lonMax = double.tryParse(_lonMaxController.text);

    if (latMin == null || latMax == null || lonMin == null || lonMax == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("❌ Coordonnées invalides")),
      );
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => SurveillancePage(
          latMin: latMin,
          latMax: latMax,
          lonMin: lonMin,
          lonMax: lonMax,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Définir la zone de surveillance')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _latMinController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: "Latitude min"),
            ),
            TextField(
              controller: _latMaxController,
              keyboardType: TextType.number,
              decoration: const InputDecoration(labelText: "Latitude max"),
            ),
            TextField(
              controller: _lonMinController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: "Longitude min"),
            ),
            TextField(
              controller: _lonMaxController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: "Longitude max"),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _demarrerSurveillance,
              child: const Text("🚀 Démarrer la surveillance"),
            ),
          ],
        ),
      ),
    );
  }
}

class CelluleBTST {
  final List<LatLng> points;
  final Color couleur;
  final LatLng centre;
  final Map<String, dynamic> infos;

  CelluleBTST({
    required this.points,
    required this.couleur,
    required this.centre,
    required this.infos,
  });
}

class SurveillancePage extends StatefulWidget {
  final double latMin, latMax, lonMin, lonMax;

  const SurveillancePage({
    super.key,
    required this.latMin,
    required this.latMax,
    required this.lonMin,
    required this.lonMax,
  });

  @override
  State<SurveillancePage> createState() => _SurveillancePageState();
}

class _SurveillancePageState extends State<SurveillancePage> {
  String _status = "Téléchargement en cours...";
  String? _fichierTelecharge;
  List<CelluleBTST> _cellules = [];
  LatLng _centreCarte = LatLng(9.5, 9.0);
  Timer? _timer;
  String _derniereMaj = "";
  final int _intervalleMinutes = 30;

  @override
  void initState() {
    super.initState();
    _telechargerBTST();
    _timer = Timer.periodic(Duration(minutes: _intervalleMinutes), (_) {
      _telechargerBTST();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _telechargerBTST() async {
    DateTime now = DateTime.now().toUtc();
    DateTime limite = now.subtract(const Duration(hours: 1));
    DateTime dt = DateTime.utc(now.year, now.month, now.day, now.hour, (now.minute ~/ 15) * 15);

    while (dt.isAfter(limite) || dt.isAtSameMomentAs(limite)) {
      final String dtStr = _formatDate(dt);
      final String filename = "RDT_${dtStr}00_MSG_fulldomain_epsg4326_BTST.geojson";
      final String url = "http://sgbd.acmad.org:8080/thredds/fileServer/RDT/${dtStr.substring(0, 8)}/$dtStr/$filename";

      try {
        final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
        if (response.statusCode == 200) {
          final dir = await getApplicationDocumentsDirectory();
          final filePath = "${dir.path}/$filename";
          final file = File(filePath);
          await file.writeAsBytes(response.bodyBytes);

          setState(() {
            _status = "✅ Fichier téléchargé : $filename";
            _fichierTelecharge = filePath;
            _derniereMaj = DateTime.now().toLocal().toString().split('.')[0];
          });

          await _traiterFichierGeojson(filePath);
          return;
        }
      } catch (_) {}

      dt = dt.subtract(const Duration(minutes: 15));
    }

    setState(() {
      _status = "❌ Aucun fichier BTST trouvé dans l’heure écoulée.";
    });
  }

  Future<void> _traiterFichierGeojson(String filePath) async {
    final contenu = await File(filePath).readAsString();
    final json = jsonDecode(contenu);

    List<CelluleBTST> result = [];

    final features = json['features'] as List<dynamic>;
    for (final feature in features) {
      final props = feature['properties'];
      final geom = feature['geometry'];

      final leadtime = props['LeadTime'].toString();
      if (leadtime != "0") continue;

      final stage = props['Stage']?.toString().trim().toLowerCase() ?? "";

      final coords = geom['coordinates'];
      if (geom['type'] != "Polygon" || coords == null || coords.isEmpty) continue;

      final List<LatLng> points = [];

      for (final pt in coords[0]) {
        final lon = pt[0];
        final lat = pt[1];
        if (lat >= widget.latMin && lat <= widget.latMax &&
            lon >= widget.lonMin && lon <= widget.lonMax) {
          points.add(LatLng(lat, lon));
        }
      }

      if (points.isNotEmpty) {
        final color = _couleurSelonStage(stage);
        final LatLng centre = points.reduce((a, b) => LatLng(
          (a.latitude + b.latitude) / 2,
          (a.longitude + b.longitude) / 2,
        ));

        result.add(CelluleBTST(
          points: points,
          couleur: color,
          centre: centre,
          infos: props,
        ));
      }
    }

    if (result.isNotEmpty) {
      setState(() {
        _cellules = result;
        _centreCarte = _cellules[0].centre;
      });
    }
  }

  Color _couleurSelonStage(String stage) {
    switch (stage) {
      case "naissance":
        return Colors.blue;
      case "naissance par fission":
        return Colors.green;
      case "croissance":
        return Colors.black;
      case "mature":
        return Colors.red;
      case "décroissance":
        return Colors.orange;
      case "décroissance par fusion":
        return Colors.grey;
      default:
        return Colors.purple;
    }
  }

  void _afficherPopup(Map<String, dynamic> infos) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("📋 Détails de la cellule"),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: infos.entries.map((e) => Text("${e.key} : ${e.value}")).toList(),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Fermer"),
            )
          ],
        );
      },
    );
  }

  String _formatDate(DateTime dt) {
    return "${dt.year.toString().padLeft(4, '0')}"
           "${dt.month.toString().padLeft(2, '0')}"
           "${dt.day.toString().padLeft(2, '0')}"
           "${dt.hour.toString().padLeft(2, '0')}"
           "${dt.minute.toString().padLeft(2, '0')}";
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Surveillance en cours')),
      body: _fichierTelecharge == null
          ? Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("Latitude : ${widget.latMin} – ${widget.latMax}"),
                  Text("Longitude : ${widget.lonMin} – ${widget.lonMax}"),
                  const SizedBox(height: 20),
                  Text("🛰️ $_status"),
                ],
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_derniereMaj.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Text(
                      "🕒 Dernière mise à jour : $_derniereMaj",
                      style: const TextStyle(fontSize: 14, fontStyle: FontStyle.italic),
                    ),
                  ),
                Expanded(
                  child: FlutterMap(
                    options: MapOptions(center: _centreCarte, zoom: 6.0),
                    children: [
                      TileLayer(
                        urlTemplate: "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
                        userAgentPackageName: 'com.example.btst_surveillance',
                      ),
                      PolygonLayer(
                        polygons: _cellules.map((cell) => Polygon(
                          points: cell.points,
                          color: cell.couleur.withOpacity(0.5),
                          borderColor: cell.couleur,
                          borderStrokeWidth: 2,
                        )).toList(),
                      ),
                      MarkerLayer(
                        markers: _cellules.map((cell) => Marker(
                          point: cell.centre,
                          width: 30,
                          height: 30,
                          builder: (context) => GestureDetector(
                            onTap: () => _afficherPopup(cell.infos),
                            child: const Icon(Icons.location_on, color: Colors.black),
                          ),
                        )).toList(),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

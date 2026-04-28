import 'package:flutter/material.dart';

// Visual buckets for the 19 disturbance-type groups (see
// disturbance_types.dart). Six hues, chosen so a list of selected types
// can be skimmed by *kind of impact* before reading the labels.
//
//   blue   — recreation / people    (1 Sprehajalci, 2 Kopalci, 3 Prireditve, 8 Taborjenje)
//   orange — motorized              (4 Vožnja v naravi, 5 Vožnja po cestah, 6 Plovba, 7 Zrakoplovi)
//   red    — extraction / firearms  (9 Lov, 10 Ribolov, 11 Vojska)
//   teal   — wildlife observation   (12 Kadavri, 13 Raziskave)
//   brown  — land use               (14 Kmetijstvo, 15 Gozdarstvo, 16 Vode)
//   slate  — built / waste          (17 Odlagališča, 18 Infrastruktura, 19 Objekti)
//
// Green is intentionally absent — it's reserved for the app's own primary.
const Map<String, Color> _hueByGroupCode = {
  '1': Color(0xFF1976D2),
  '2': Color(0xFF1976D2),
  '3': Color(0xFF1976D2),
  '8': Color(0xFF1976D2),
  '4': Color(0xFFEF6C00),
  '5': Color(0xFFEF6C00),
  '6': Color(0xFFEF6C00),
  '7': Color(0xFFEF6C00),
  '9': Color(0xFFC62828),
  '10': Color(0xFFC62828),
  '11': Color(0xFFC62828),
  '12': Color(0xFF00796B),
  '13': Color(0xFF00796B),
  '14': Color(0xFF6D4C41),
  '15': Color(0xFF6D4C41),
  '16': Color(0xFF6D4C41),
  '17': Color(0xFF455A64),
  '18': Color(0xFF455A64),
  '19': Color(0xFF455A64),
};

const Color _fallback = Color(0xFF616161);

Color disturbanceGroupColor(String groupCode) =>
    _hueByGroupCode[groupCode] ?? _fallback;

Color disturbanceGroupTint(String groupCode) =>
    disturbanceGroupColor(groupCode).withValues(alpha: 0.12);

Color disturbanceGroupBorder(String groupCode) =>
    disturbanceGroupColor(groupCode).withValues(alpha: 0.45);

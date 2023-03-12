// Licensed to the Apache Software Foundation (ASF) under one
// or more contributor license agreements.  See the NOTICE file
// distributed with this work for additional information
// regarding copyright ownership.  The ASF licenses this file
// to you under the Apache License, Version 2.0 (the
// "License"); you may not use this file except in compliance
// with the License.  You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import 'dart:io';
import 'dart:typed_data';
import 'package:logging/logging.dart';
import 'package:bonsoir/bonsoir.dart';
import 'package:cryptography_flutter/cryptography_flutter.dart';
import 'package:cryptography/cryptography.dart';
import 'package:convert/convert.dart';
import 'package:netpaddle/name_generator.dart';

/// Game Data to pack and send, or receive and unpack for networking.
///
/// Need to normalize by assuming screen width and height are 0 to 1.
/// Need to flip Y on receive as opponent sees it upside down to each other.
/// Need to swap myScore and oppoScore on receive for same reason.
class GameNetData {
  static const double normFloatBase = 1000000.0; // express float as fraction

  final int gameID; // to make sure we are playing the same game!
  final int count; // need to be sent as Int32 or underflow may happen
  final double px, bx, by, bvx, bvy;
  final int myScore, oppoScore;
  final double pause;
  final String name;

  GameNetData(
    this.gameID,
    this.count,
    this.px,
    this.bx,
    this.by,
    this.bvx,
    this.bvy,
    this.pause,
    this.myScore,
    this.oppoScore,
    this.name,
  );

  static int normFloatToInt(double nf) => (nf.clamp(-1.0, 1.0) * normFloatBase).round();

  static double normIntToFloat(int ni) => (ni / normFloatBase).clamp(-1.0, 1.0);

  GameNetData.fromPayload(Uint32List data)
      : gameID = data[0],
        count = data[1],
        px = normIntToFloat(data[2]),
        bx = normIntToFloat(data[3]),
        by = normIntToFloat(data[4]),
        bvx = normIntToFloat(data[5]),
        bvy = normIntToFloat(data[6]),
        pause = normIntToFloat(data[7]),
        myScore = data[8],
        oppoScore = data[9],
        name = String.fromCharCodes(data, 11, 11 + data[10]);

  Int32List toNetBundle() {
    return Int32List.fromList([
      gameID,
      count,
      normFloatToInt(px),
      normFloatToInt(bx),
      normFloatToInt(by),
      normFloatToInt(bvx),
      normFloatToInt(bvy),
      normFloatToInt(pause),
      myScore,
      oppoScore,
      name.length,
      ...name.codeUnits
    ]);
  }
}

/// Networking Service for Host and Guest, incl discovery & communication.
class GameNetSvc {
  static const enableCrypto = true;
  static const svcType = '_net_paddle._udp';
  static const svcPort = 13579;
  static const String gameIDAttrib = "game_id";
  static const String secretAttrib = "secret";

  static final log = Logger("GameNetSvc");

  static final Cipher crypto = FlutterAesGcm(secretKeyLength: 32);

  String _myName = "";
  String get myName => _myName;
  Uint8List? _gameNonce;
  SecretKey? _secretKey;
  BonsoirService? _mySvc; // network game I am hosting
  BonsoirBroadcast? _myBroadcast;
  final Map<String, ResolvedBonsoirService> _host2svc = {}; // other hosts
  final Function _onDiscovery;
  InternetAddress? _myAddress;
  InternetAddress? _oppoAddress;
  String? _oppoName;
  RawDatagramSocket? _sock;

  GameNetSvc(Uint8List addressIPv4, this._onDiscovery) {
    try {
      _myAddress = InternetAddress.fromRawAddress(addressIPv4);
    } catch (e) {
      log.warning(e);
      _myAddress = null;
    }
    _scan();
  }

  Iterable<String> get serviceNames => _host2svc.keys;
  Uint8List get gameNonce => _gameNonce!;
  int get gameID => gameNonce.buffer.asUint32List().first;
  String get oppoName => _oppoName!;

  Uint8List bitmask(Uint8List bytes, int byteMask) =>
      Uint8List.fromList(bytes.map((b) => b ^ byteMask).toList());

  Future<void> _scan() async {
    BonsoirDiscovery discovery = BonsoirDiscovery(type: svcType);
    await discovery.ready;
    await discovery.start();

    discovery.eventStream?.listen((e) {
      if (_mySvc?.name != e.service!.name) {
        if (e.service != null && e.service!.name.isNotEmpty) {
          if (e.type == BonsoirDiscoveryEventType.discoveryServiceResolved) {
            log.info("Found service at ${e.service!.name}...");
            _host2svc[e.service!.name] = (e.service) as ResolvedBonsoirService;
            _onDiscovery();
          } else if (e.type == BonsoirDiscoveryEventType.discoveryServiceLost) {
            log.info("Lost service at ${e.service!.name}...");

            _host2svc.remove(e.service!.name);
            _onDiscovery();
          }
        }
      }
    });
  }

  Future<void> startHosting(Function(GameNetData p) onMsg, Function() onDone) async {
    _safeCloseSocket();
    await _safeStopBroadcast();

    _myName = NameGenerator.genNewName(_myAddress!.rawAddress, knownNames: _host2svc.keys);

    final addrLastByte = _myAddress!.rawAddress.last;
    _gameNonce = Uint8List.fromList(enableCrypto ? crypto.newNonce() : [0, 0, 0, 0]);
    _secretKey = await crypto.newSecretKey();
    final secretBytes = Uint8List.fromList(enableCrypto ? await _secretKey!.extractBytes() : [0]);
    // as added precaution, secret is XOR with last byte of host address
    final maskedNonceBytes = enableCrypto ? bitmask(gameNonce, addrLastByte) : gameNonce;
    final maskedSecretBytes = enableCrypto ? bitmask(secretBytes, addrLastByte) : secretBytes;
    _mySvc = BonsoirService(
      name: myName,
      type: svcType,
      port: svcPort,
      attributes: {
        gameIDAttrib: hex.encode(maskedNonceBytes),
        secretAttrib: hex.encode(maskedSecretBytes),
      },
    );

    _myBroadcast = BonsoirBroadcast(service: _mySvc!);
    await _myBroadcast?.ready;
    await _myBroadcast?.start();

    _sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, svcPort);
    log.info("Start Hosting game @ $_myAddress as $myName...");
    _sock!.listen(
      (evt) => _onEvent(onMsg, evt),
      onError: (err) => _finishedHandler(onDone, err),
      onDone: () => _finishedHandler(onDone),
      cancelOnError: true,
    );
  }

  Future<void> stopBroadcasting() async {
    log.info("Stop Broadcasting game as $myName...");
    await _safeStopBroadcast();
  }

  Future<void> stopHosting() async {
    log.info("Stop Hosting game as $myName...");
    _safeCloseSocket();
    await _safeStopBroadcast();
  }

  Future<void> joinGame(
    String name,
    void Function(GameNetData) onMsg,
    void Function() onDone,
  ) async {
    log.info("Joining game hosted by $name...");
    final hostSvc = _host2svc[name];
    if (hostSvc != null && hostSvc.ip != null) {
      _oppoAddress = InternetAddress(hostSvc.ip!);
      final addrLastByte = _oppoAddress!.rawAddress.last;
      final maskedNonceBytes = Uint8List.fromList(
        hex.decode(hostSvc.attributes![gameIDAttrib]!),
      );
      final maskedSecretBytes = Uint8List.fromList(
        hex.decode(hostSvc.attributes![secretAttrib]!),
      );

      if (enableCrypto) {
        // as added precaution, game ID & secret is XOR with last byte of host address
        _gameNonce = bitmask(maskedNonceBytes, addrLastByte);
        final secretBytes = bitmask(maskedSecretBytes, addrLastByte);
        _secretKey = SecretKeyData(secretBytes);
      } else {
        _gameNonce = maskedNonceBytes;
      }

      log.info("Joining net game $name @ $_oppoAddress as $myName...");
      _oppoName = name;
      _sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, svcPort);
      _sock!.listen(
        (evt) => _onEvent(onMsg, evt),
        onError: (err) => _finishedHandler(onDone, err),
        onDone: () => _finishedHandler(onDone),
        cancelOnError: true,
      );
    } else {
      log.warning("$name is no longer broadcasting...");
      _finishedHandler(onDone);
    }
  }

  Future<void> leaveGame() async {
    log.info("Leaving net game...");
    _safeCloseSocket();
  }

  Future<void> send(GameNetData data) async {
    if (_sock != null) {
      final dataBytes = data.toNetBundle().buffer.asUint8List();

      late final Uint8List payload;
      if (enableCrypto) {
        // as added precaution data sent is XOR masked by sender address last byte
        final myAddrLastByte = _myAddress!.rawAddress.last;
        final maskedDataBytes = bitmask(dataBytes, myAddrLastByte);
        final secretBox =
            await crypto.encrypt(maskedDataBytes, secretKey: _secretKey!, nonce: _gameNonce);
        payload = secretBox.concatenation();
      } else {
        payload = dataBytes;
      }

      _sock!.send(
        payload,
        _oppoAddress!,
        svcPort,
      );
    }
  }

  Future<void> _onEvent(Function(GameNetData) onMsg, RawSocketEvent event) async {
    if (event == RawSocketEvent.read && _sock != null) {
      final payload = _sock!.receive();
      if (payload == null) return;

      // if receiving first packet from opponent, set oppo address, else check
      final fromAddr = payload.address;
      if (_oppoAddress == null) {
        _oppoAddress = fromAddr;
      } else if (fromAddr != _oppoAddress) {
        log.warning("Rejecting message from unexpected address $fromAddr");
        return;
      }

      late final Uint8List dataBytes;
      if (enableCrypto) {
        final secretBox = SecretBox.fromConcatenation(
          payload.data,
          nonceLength: crypto.nonceLength,
          macLength: crypto.macAlgorithm.macLength,
        );
        final maskedPayload =
            Uint8List.fromList(await crypto.decrypt(secretBox, secretKey: _secretKey!));

        // as added precaution data sent is XOR masked by sender address last byte
        final oppoAddrLastByte = _oppoAddress!.rawAddress.last;
        final payloadBytes = bitmask(maskedPayload, oppoAddrLastByte);
        dataBytes = Uint8List.fromList(payloadBytes);
      } else {
        dataBytes = payload.data;
      }

      final GameNetData data = GameNetData.fromPayload(dataBytes.buffer.asUint32List());
      if (_oppoName == null) {
        _oppoName = data.name;
      } else if (_oppoName != data.name) {
        log.warning("Rejecting message from unexpected name $data.name, should be $_oppoName");
        return;
      }

      // make sure data is has right game
      if (data.gameID != gameID) {
        log.warning("Ignoring message from unexpected address $fromAddr "
            "due to mismatched gameID ${data.gameID} expecting $gameID");
        return;
      }
      onMsg(data);
    }
  }

  void _finishedHandler(Function() onDone, [Object? e]) {
    if (e != null) log.severe(e);
    log.info("Finishing net game...");
    onDone();
  }

  void _safeCloseSocket() {
    log.info("Closing socket...");
    _sock?.close();
    _sock = null;
    _oppoAddress = null;
  }

  Future<void> _safeStopBroadcast() async {
    log.info("Stopping broadcast...");
    await _myBroadcast?.stop();
    _myBroadcast = null;
    _mySvc = null;
  }
}

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
import 'dart:math';
import 'dart:typed_data';
import 'package:bonsoir/bonsoir.dart';
import 'package:logging/logging.dart';

/// Game Data to pack and send, or receive and unpack for networking.
///
/// Need to normalize by assuming screen width and height are 0 to 1.
/// Need to flip Y on receive as opponent sees it upside down to each other.
/// Need to swap myScore and oppoScore on receive for same reason.
class GameNetData {
  static const double NORM_FLOAT_BASE = 1000000.0; // express float as fraction

  final int count; // need to be sent as Int32 or underflow may happen
  final double px, bx, by, bvx, bvy;
  final int myScore, oppoScore;
  final double pause;

  GameNetData(
    this.count,
    this.px,
    this.bx,
    this.by,
    this.bvx,
    this.bvy,
    this.pause,
    this.myScore,
    this.oppoScore,
  );

  static int normFloatToInt(double nf) =>
      (nf.clamp(-1.0, 1.0) * NORM_FLOAT_BASE).round();

  static double normIntToFloat(int ni) =>
      (ni / NORM_FLOAT_BASE).clamp(-1.0, 1.0);

  GameNetData.fromPayload(Int32List data)
      : count = data[0],
        px = normIntToFloat(data[1]),
        bx = normIntToFloat(data[2]),
        by = normIntToFloat(data[3]),
        bvx = normIntToFloat(data[4]),
        bvy = normIntToFloat(data[5]),
        pause = normIntToFloat(data[6]),
        myScore = data[7],
        oppoScore = data[8];

  Int32List toNetBundle() {
    return Int32List.fromList([
      count,
      normFloatToInt(px),
      normFloatToInt(bx),
      normFloatToInt(by),
      normFloatToInt(bvx),
      normFloatToInt(bvy),
      normFloatToInt(pause),
      myScore,
      oppoScore,
    ]);
  }
}

/// Networking Service for Host and Guest, incl discovery & communication.
class GameNetSvc {
  static const SVC_TYPE = '_net_paddle._udp';
  static const SVC_PORT = 13579;

  static final log = Logger("GameNetSvc");

  final String myName;
  final int cryptKey = Random().nextInt(1 << 32);
  BonsoirService? _mySvc; // network game I am hosting
  BonsoirBroadcast? _myBroadcast;
  Map<String, ResolvedBonsoirService> _host2svc = {}; // other hosts
  Function _onDiscovery;
  InternetAddress? _myAddress;
  InternetAddress? _oppoAddress;
  RawDatagramSocket? _sock;

  GameNetSvc(Uint8List addressIPv4, this.myName, this._onDiscovery) {
    try {
      _myAddress = InternetAddress.fromRawAddress(addressIPv4);
    } catch (e) {
      log.warning(e);
      _myAddress = null;
    }
    _scan();
  }

  Iterable<String> get serviceNames => _host2svc.keys;

  void _scan() async {
    BonsoirDiscovery discovery = BonsoirDiscovery(type: SVC_TYPE);
    await discovery.ready;
    await discovery.start();

    discovery.eventStream?.listen((e) {
      if (e.service != null && e.service!.name.isNotEmpty) {
        if (e.type == BonsoirDiscoveryEventType.DISCOVERY_SERVICE_RESOLVED) {
          log.info("Found service at ${e.service!.name}...");

          if (_mySvc?.name != e.service!.name) {
            _host2svc[e.service!.name] = (e.service) as ResolvedBonsoirService;
            this._onDiscovery();
          }
        } else if (e.type == BonsoirDiscoveryEventType.DISCOVERY_SERVICE_LOST) {
          log.info("Lost service at ${e.service!.name}...");

          _host2svc.remove(e.service!.name);
          this._onDiscovery();
        }
      }
    });
  }

  void startHosting(Function(GameNetData p) onMsg, Function() onDone) async {
    _safeCloseSocket();
    await _safeStopBroadcast();

    _mySvc = BonsoirService(
      name: myName,
      type: SVC_TYPE,
      port: SVC_PORT,
      attributes: {'key': cryptKey.toString()},
    );

    _myBroadcast = BonsoirBroadcast(service: _mySvc!);
    await _myBroadcast?.ready;
    await _myBroadcast?.start();

    _safeCloseSocket();
    _sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, SVC_PORT);
    log.info("Start Hosting game @ $_myAddress as $myName...");
    _sock!.listen(
      (evt) => _onEvent(onMsg, evt),
      onError: (err) => _finishedHandler(onDone, err),
      onDone: () => _finishedHandler(onDone),
      cancelOnError: true,
    );
  }

  void stopBroadcasting() async {
    log.info("Stop Broadcasting game as $myName...");
    await _safeStopBroadcast();
  }

  void stopHosting() async {
    log.info("Stop Hosting game as $myName...");
    _safeCloseSocket();
  }

  void joinGame(
    String name,
    void Function(GameNetData) onMsg,
    void Function() onDone,
  ) async {
    log.info("Joining game hosted by $name...");
    final hostSvc = _host2svc[name];
    if (hostSvc != null && hostSvc.ip != null) {
      _oppoAddress = InternetAddress(hostSvc.ip!);
      log.info("Joining net game $name @ $_oppoAddress as $myName...");
      _safeCloseSocket();
      _sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, SVC_PORT);
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

  void leaveGame() {
    log.info("Leaving net game...");
    _safeCloseSocket();
  }

  void send(GameNetData data) {
    if (_sock != null) {
      _sock!.send(
        data.toNetBundle().buffer.asInt8List(),
        _oppoAddress!,
        SVC_PORT,
      );
    }
  }

  void _onEvent(Function(GameNetData) onMsg, RawSocketEvent event) {
    if (event == RawSocketEvent.read && _sock != null) {
      final packet = _sock!.receive();
      if (packet == null) return;
      final data = GameNetData.fromPayload(packet.data.buffer.asInt32List());
      _oppoAddress = packet.address;
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
  }

  Future<void> _safeStopBroadcast() async {
    log.info("Stopping broadcast...");
    await _myBroadcast?.stop();
    _myBroadcast = null;
    _mySvc = null;
  }
}

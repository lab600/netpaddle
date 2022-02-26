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

import 'dart:math';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:flame/input.dart';
import 'package:flame/game.dart';
import 'package:flame/widgets.dart';
import 'package:flame_audio/bgm.dart';
import 'package:flame_audio/flame_audio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:synchronized/synchronized.dart';
import 'name_generator.dart';
import 'pixel_mapper.dart';
import 'constants.dart';
import 'pad.dart';
import 'ball.dart';
import 'net_svc.dart';

/// Enum to mark which mode the game is currently in
enum GameMode {
  over, // game is over, showing game over menu
  single, // playing as single player against computer
  wait, // waiting as host for any guest to connect, show waiting menu
  host, // playing as host over network
  guest, // playing as guest over network
}

/// The Game class to keep game states and implement controller logic
class PaddleGame extends FlameGame with HorizontalDragDetector {
  static final log = Logger("PaddleGame");

  static const MAIN_MENU_OVERLAY_ID = 'MainMenuOverlay';
  static const HOST_WAITING_OVERLAY_ID = 'HostWaitingOverlay';
  static const TOP_MARGIN = 0.05;
  static const BOTTOM_MARGIN = 0.95;
  static const MAX_SCORE = 3;
  static const INIT_WTH = 100.0; // interim value before game size ready
  static const INIT_HGT = 200.0; // interim value before game size ready
  static const MAX_NET_WAIT = Duration(seconds: 10); // opponent disconnected
  static const HIT_WAIT = Duration(milliseconds: 60); // guard repeated hits
  static const MAX_SEND_GAP = 0.025; // max of 40 network update/sec

  final TextPaint _txtPaint = TextPaint(
    style: const TextStyle(fontSize: 14.0, color: Colors.white),
  );

  final lock = new Lock(); // support concurrency during network callback

  late final String _myNetHandle;
  late final GameNetSvc? _netSvc;
  late final Map<String, OverlayWidgetBuilder<PaddleGame>> overlayMap;
  late PixelMapper _pxMap;
  late final Pad myPad;
  late final Pad oppoPad;
  late final Ball ball;

  Bgm _music = FlameAudio.bgm..initialize();
  bool _firstLoad = true;
  String _oppoHostHandle = "";
  String _gameMsg = "";
  String get gameMsg => _gameMsg;
  int _myScore = 0;
  int _oppoScore = 0;
  int _sendCount = 0; // to tag network packet sent for ordering
  int _receiveCount = -1; // to detect out-of-order network packet received
  double _sinceLastSent = 0; // used to limit network updates

  GameMode _mode = GameMode.over; // private so only Game can change mode
  DateTime _lastReceiveTime = clock.now();

  // allow read access to these states
  GameMode get mode => _mode;
  bool get isOver => mode == GameMode.over;
  bool get isGuest => mode == GameMode.guest;
  bool get isHost => mode == GameMode.host;
  bool get isWaiting => mode == GameMode.wait;
  bool get isSingle => mode == GameMode.single;
  int get myScore => _myScore;
  int get oppoScore => _oppoScore;
  double get topMargin => _pxMap.toDevY(TOP_MARGIN);
  double get bottomMargin => _pxMap.toDevY(BOTTOM_MARGIN);
  double get leftMargin => _pxMap.toDevX(0.0);
  double get rightMargin => _pxMap.toDevX(1.0);

  PaddleGame(Uint8List? addressIPv4) {
    _myNetHandle = NameGenerator.genNewName(addressIPv4);
    _pxMap = PixelMapper(gameWidth: INIT_WTH, gameHeight: INIT_HGT);
    myPad = Pad(gameWidth: INIT_WTH, gameHeight: INIT_HGT);
    oppoPad = Pad(gameWidth: INIT_WTH, gameHeight: INIT_HGT, isPlayer: false);
    ball = Ball(gameWidth: INIT_WTH, gameHeight: INIT_HGT);

    // only offer playing over network if not web and has real IP address
    _netSvc = kIsWeb || addressIPv4 == null
        ? null
        : GameNetSvc(addressIPv4, _myNetHandle, _onDiscovery);

    overlayMap = {
      MAIN_MENU_OVERLAY_ID: mainMenuOverlay,
      HOST_WAITING_OVERLAY_ID: hostWaitingOverlay,
    };
  }

  /// When game is first loaded:
  /// * cache all audio files,
  /// * make game aware of 3 components: player's pad, opponent's pad, and ball,
  /// * show the main menu overlay
  @override
  Future<void> onLoad() async {
    await super.onLoad();

    await FlameAudio.audioCache.loadAll([
      CRASH_FILE,
      POP_FILE,
      TADA_FILE,
      WAH_FILE,
      BKGND_FILE,
      PLAY_FILE,
      WHISTLE_FILE,
    ]);

    add(myPad);
    add(oppoPad);
    add(ball);
    showMainMenu();
  }

  /// show main menu, start background music if not on first load
  void showMainMenu() async {
    // don't play music on first load if web or first load to avoid error msgs
    if (!kIsWeb || !_firstLoad) {
      await _music.stop();
      await _music.play(BKGND_FILE);
    }
    refreshMainMenu();
  }

  /// refresh main menu so newly detected game hosts cqn be displayed
  void refreshMainMenu() async {
    overlays.remove(MAIN_MENU_OVERLAY_ID);
    overlays.add(MAIN_MENU_OVERLAY_ID);
  }

  /// reset the game to specific mode and starting state for it.
  void _reset([GameMode mode = GameMode.over]) {
    _firstLoad = false;
    _mode = mode;
    _myScore = 0;
    _oppoScore = 0;
    _receiveCount = -1;
    final bvy = isHost || isSingle ? Ball.NORM_SPEED : 0.0;
    myPad.reset();
    _lastReceiveTime = clock.now();
    ball.reset(
      normVY: bvy,
      normX: 0.5,
      normY: 0.5,
    );
  }

  /// on resize, recalibrate the pixel mapper to match new dimensions
  @override
  void onGameResize(Vector2 gameSize) {
    super.onGameResize(gameSize);
    _pxMap = PixelMapper(gameWidth: gameSize.x, gameHeight: gameSize.y);
  }

  /// reusable logic to generate a Button and backing logic
  Widget gameButton(String txt, void Function() handler) => Padding(
        padding: EdgeInsets.symmetric(vertical: 20.0),
        child: SizedBox(
          width: _pxMap.toDevWth(.7),
          child: ElevatedButton(
            child: Text(
              txt,
              textAlign: TextAlign.center,
            ),
            onPressed: handler,
          ),
        ),
      );

  /// widget tree for the main menu overlay
  Widget mainMenuOverlay(BuildContext ctx, PaddleGame game) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (game.gameMsg.isNotEmpty)
              Padding(
                padding: EdgeInsets.symmetric(vertical: 20.0),
                child: Text(game.gameMsg),
              ),
            gameButton('Single Player', game.startSinglePlayer),

            /// can't support hosting net game when playing in browser
            if (!kIsWeb) gameButton('Host Network Game', game.hostNetGame),

            /// can't support joining net game as guest when playing in browser
            if (!kIsWeb)
              for (var svc in game._netSvc!.serviceNames)
                gameButton('Play $svc', () => game.joinNetGame(svc))
          ],
        ),
      );

  /// widget tree for the overlay waiting for guest to join player hosted game
  Widget hostWaitingOverlay(BuildContext ctx, PaddleGame game) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Padding(
              padding: EdgeInsets.symmetric(vertical: 20.0),
              child: Text('Hosting Game as ${game._myNetHandle}...'),
            ),
            gameButton('Cancel', game.stopHosting),
          ],
        ),
      );

  /// horizontal drag will update player's paddle direction: left or right
  @override
  void onHorizontalDragUpdate(DragUpdateInfo info) {
    final dragX = info.delta.global.x;
    final endX = info.eventPosition.global.x;
    if (endX >= myPad.x - myPad.width / 2 &&
        endX <= myPad.x + myPad.width / 2) {
      myPad.setPlayerStationary();
    } else if (dragX < 0) {
      myPad.movePlayerLeft();
    } else if (dragX > 0) {
      myPad.movePlayerRight();
    }
  }

  /// when end of drag detected, stop moving player's paddle
  @override
  void onHorizontalDragEnd(DragEndInfo info) {
    myPad.setPlayerStationary();
  }

  /// start Single Player game
  void startSinglePlayer() async {
    overlays.remove(MAIN_MENU_OVERLAY_ID);
    if (isSingle) return;
    _reset(GameMode.single);
    ball.reset(normVY: Ball.NORM_SPEED);
    FlameAudio.play(WHISTLE_FILE);
    await _music.stop();
    await _music.play(PLAY_FILE);
  }

  /// start hosting a net game, synchronized just in case of repeated clicks
  void hostNetGame() {
    lock.synchronized(() {
      overlays.remove(MAIN_MENU_OVERLAY_ID);
      overlays.add(HOST_WAITING_OVERLAY_ID);

      if (isWaiting) return;

      _reset(GameMode.wait);
      _netSvc!.startHosting(_updateOnReceive, endGame);
    });
  }

  /// stop hosting net game, synchronized just in case of repeated clicks
  void stopHosting() {
    lock.synchronized(() async {
      _netSvc?.stopHosting();
      _reset(GameMode.over);
      overlays.remove(HOST_WAITING_OVERLAY_ID);
      overlays.add(MAIN_MENU_OVERLAY_ID);
    });
  }

  /// join a net game by name, synchronized just in case of repeated clicks
  void joinNetGame(String netGameName) async {
    lock.synchronized(() async {
      overlays.remove(MAIN_MENU_OVERLAY_ID);
      _reset(GameMode.guest);
      _netSvc?.joinGame(netGameName, _updateOnReceive, endGame);
      _oppoHostHandle = netGameName;
      await FlameAudio.play(WHISTLE_FILE);
      await _music.stop();
      _music.play(PLAY_FILE);
    });
  }

  /// increment player's score limit by MAX_SCORE
  void addMyScore() async {
    await FlameAudio.play(CRASH_FILE);
    _myScore = min(_myScore + 1, MAX_SCORE);
  }

  /// increment opponent score limit by MAX_SCORE
  void addOpponentScore() async {
    await FlameAudio.play(CRASH_FILE);
    _oppoScore = min(_oppoScore + 1, MAX_SCORE);
  }

  /// end the game
  /// * play victory or defeat music
  /// * nicely end net games if needed
  /// * set mode to game over
  /// * show main menu
  void endGame() async {
    lock.synchronized(() async {
      if (isOver) return;

      if (myScore >= MAX_SCORE) {
        await FlameAudio.play(TADA_FILE);
      } else if (_oppoScore >= MAX_SCORE) {
        await FlameAudio.play(WAH_FILE);
      }

      if (isGuest) _netSvc?.leaveGame();
      if (isHost) _netSvc?.stopHosting();

      _mode = GameMode.over;

      showMainMenu();
    });
  }

  /// on new host discovery, add it to main menu by refreshing it
  void _onDiscovery() {
    if (isOver) refreshMainMenu(); // update game over menu only when isOver
  }

  /// update game state when receiving new net data from opponent.
  /// will check receiving order, guard against race condition from rapid
  /// updates when a ball just changed direction by pausing update for HIT_WAIT.
  void _updateOnReceive(GameNetData data) async {
    lock.synchronized(() async {
      _lastReceiveTime = clock.now();

      if (mode == GameMode.wait) {
        log.info("Received msg from guest, starting game as host...");
        _netSvc!.stopBroadcasting();
        overlays.remove(HOST_WAITING_OVERLAY_ID);
        _mode = GameMode.host;
        _receiveCount = data.count;
        ball.reset(normVY: Ball.NORM_SPEED, normX: .5, normY: .5);
        await FlameAudio.play(WHISTLE_FILE);
        await _music.stop();
        await _music.play(PLAY_FILE);
      } else if (ball.vy == 0 && data.bvy != 0) {
        log.info("Guest just got the first update from host...");
        _receiveCount = data.count;
      } else if (data.count < _receiveCount) {
        log.warning("Received data count ${data.count} less than last "
            "received count $_receiveCount, ignored...");
        return;
      } else if (_lastReceiveTime.isBefore(ball.lastHitTime.add(HIT_WAIT))) {
        log.warning("Received data less than last hit time + wait, ignored...");
        return;
      }

      _receiveCount = data.count;
      oppoPad.setOpponentPos(_pxMap.toDevX(1.0 - data.px));

      if (data.by > 0.8 && data.bvy < 0 && ball.vy < 0) {
        // ball Y direction changed, opponent must have detected hit, play Pop
        FlameAudio.play(POP_FILE);
      }

      if (ball.vy < 0 || data.bvy > 0) {
        // ball going away from me let opponent update my ball state

        ball.updateOnReceive(
          data.bx,
          data.by,
          data.bvx,
          data.bvy,
          data.pause,
        );
      }

      if (myScore < data.oppoScore) {
        // score changed, opponent must have detected crashed, play Crash
        if (data.oppoScore >= MAX_SCORE) {
          endGame();
        } else {
          FlameAudio.play(CRASH_FILE);
        }
        _myScore = data.oppoScore;
      }
    });
  }

  /// send game state update to opponent
  void _sendStateUpdate() {
    final data = GameNetData(
      _sendCount++,
      _pxMap.toNormX(myPad.x),
      _pxMap.toNormX(ball.x),
      _pxMap.toNormY(ball.y),
      _pxMap.toNormWth(ball.vx),
      _pxMap.toNormHgt(ball.vy),
      ball.pause,
      myScore,
      oppoScore,
    );
    _netSvc?.send(data);
  }

  /// update by detecting if game is over, and send network update if needed
  @override
  void update(double dt) async {
    super.update(dt);
    bool gameIsOver = false;
    if (myScore >= MAX_SCORE) {
      gameIsOver = true;
      _gameMsg = "You've Won!";
    } else if (oppoScore >= MAX_SCORE) {
      gameIsOver = true;
      _gameMsg = "You've Lost!";
    } else if (isHost || isGuest) {
      final waitLimit = _lastReceiveTime.add(MAX_NET_WAIT);
      if (clock.now().isAfter(waitLimit)) {
        gameIsOver = true;
        _gameMsg = "Connection Interrupted.";
      }
    }

    if (isHost || isGuest) {
      _sinceLastSent += dt;

      /// use max send to limit num of sends
      if (_sinceLastSent >= MAX_SEND_GAP || ball.forceNetSend) {
        _sendStateUpdate();
        _sinceLastSent = 0;
      }
    }

    if (gameIsOver) endGame();
  }

  /// Render game score and mode info
  @override
  void render(Canvas canvas) {
    final scoreMsg = "Score $myScore:$oppoScore";
    _txtPaint.render(
      canvas,
      scoreMsg,
      _pxMap.toDevPos(0, 0),
      anchor: Anchor.topLeft,
    );

    late final String modeMsg;
    if (isSingle) {
      modeMsg = "Single Player";
    } else if (isHost) {
      modeMsg = "Hosting as $_myNetHandle";
    } else if (isGuest) {
      modeMsg = "Playing with $_oppoHostHandle";
    } else {
      modeMsg = "";
    }

    if (modeMsg.isNotEmpty)
      _txtPaint.render(
        canvas,
        modeMsg,
        _pxMap.toDevPos(1, 0),
        anchor: Anchor.topRight,
      );

    super.render(canvas);
  }
}

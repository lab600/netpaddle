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

  static const mainMenuOverlayKey = 'MainMenuOverlay';
  static const hostWaitingOverlayKey = 'HostWaitingOverlay';
  static const normTopMargin = 0.05;
  static const normBottomMargin = 0.95;
  static const maxScore = 3;
  static const initWidth = 100.0; // interim value before game size ready
  static const initHeight = 200.0; // interim value before game size ready
  static const maxNetWait = Duration(seconds: 10); // opponent disconnected
  static const hitWait = Duration(milliseconds: 60); // guard repeated hits
  static const maxSendGap = 0.01; // max of 100 network update/sec

  final TextPaint _txtPaint = TextPaint(
    style: const TextStyle(fontSize: 14.0, color: Colors.white),
  );

  final lock = Lock(); // support concurrency during network callback
  final Bgm _music = FlameAudio.bgm..initialize();

  late final GameNetSvc? _netSvc;
  late final Map<String, OverlayWidgetBuilder<PaddleGame>> overlayMap;
  late PixelMapper _pxMap;
  late final Pad myPad;
  late final Pad oppoPad;
  late final Ball ball;

  bool _firstLoad = true;
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
  double get topMargin => _pxMap.toDevY(normTopMargin);
  double get bottomMargin => _pxMap.toDevY(normBottomMargin);
  double get leftMargin => _pxMap.toDevX(0.0);
  double get rightMargin => _pxMap.toDevX(1.0);

  PaddleGame(Uint8List? addressIPv4) {
    _pxMap = PixelMapper(gameWidth: initWidth, gameHeight: initHeight);
    myPad = Pad(gameWidth: initWidth, gameHeight: initHeight);
    oppoPad = Pad(gameWidth: initWidth, gameHeight: initHeight, isPlayer: false);
    ball = Ball(gameWidth: initWidth, gameHeight: initHeight);

    // only offer playing over network if not web and has real IP address
    _netSvc = kIsWeb || addressIPv4 == null
        ? null
        : GameNetSvc(addressIPv4, NameGenerator.genNewName(addressIPv4), _onDiscovery);

    overlayMap = {
      mainMenuOverlayKey: mainMenuOverlay,
      hostWaitingOverlayKey: hostWaitingOverlay,
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
      crashFile,
      popFile,
      victoryFile,
      wahFile,
      backgroundFile,
      playFile,
      whistleFile,
    ]);

    add(myPad);
    add(oppoPad);
    add(ball);
    showMainMenu();
    if (!kIsWeb && _netSvc == null) {
      _gameMsg = "Join Wifi to host or join network games.";
    }

  }

  /// When game is to be removed
  /// * stop music
  @override
  void onRemove() async {
    await _music.stop();
  }

  /// show main menu, start background music if not on first load
  void showMainMenu() async {
    // don't play music on first load if web or first load to avoid error msgs
    if (!kIsWeb || !_firstLoad) {
      await _music.stop();
      await _music.play(backgroundFile);
    }
    refreshMainMenu();
  }

  /// refresh main menu so newly detected game hosts cqn be displayed
  void refreshMainMenu() async {
    overlays.remove(mainMenuOverlayKey);
    overlays.add(mainMenuOverlayKey);
  }

  /// reset the game to specific mode and starting state for it.
  void _reset([GameMode mode = GameMode.over]) {
    _firstLoad = false;
    _mode = mode;
    _myScore = 0;
    _oppoScore = 0;
    _receiveCount = -1;
    final bvy = isHost || isSingle ? Ball.normSpeed : -Ball.normSpeed;
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
        padding: const EdgeInsets.symmetric(vertical: 20.0),
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
            if (gameMsg.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 20.0),
                child: Text(gameMsg),
              ),
            gameButton('Single Player', startSinglePlayer),

            /// can't support hosting net game when playing in browser
            if (!kIsWeb && _netSvc != null)
              gameButton('Host Network Game', hostNetGame),

            /// can't support joining net game as guest when playing in browser
            if (!kIsWeb && _netSvc != null)
              for (var sName in _netSvc!.serviceNames)
                gameButton('Play $sName',
                      () => joinNetGame(sName),
                )
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
              padding: const EdgeInsets.symmetric(vertical: 20.0),
              child: Text('Hosting Game as ${_netSvc!.myName}...'),
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
    overlays.remove(mainMenuOverlayKey);
    if (isSingle) return;
    _reset(GameMode.single);
    ball.reset(normVY: Ball.normSpeed);
    FlameAudio.play(whistleFile);
    await _music.stop();
    await _music.play(playFile);
  }

  /// start hosting a net game, synchronized just in case of repeated clicks
  void hostNetGame() {
    lock.synchronized(() {
      overlays.remove(mainMenuOverlayKey);
      overlays.add(hostWaitingOverlayKey);

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
      overlays.remove(hostWaitingOverlayKey);
      overlays.add(mainMenuOverlayKey);
    });
  }

  /// join a net game by name, synchronized just in case of repeated clicks
  void joinNetGame(String netGameName) async {
    lock.synchronized(() async {
      overlays.remove(mainMenuOverlayKey);
      _reset(GameMode.guest);
      _netSvc?.joinGame(netGameName, _updateOnReceive, endGame);
      await FlameAudio.play(whistleFile);
      await _music.stop();
      _music.play(playFile);
    });
  }

  /// increment player's score limit by MAX_SCORE
  void addMyScore() async {
    await FlameAudio.play(crashFile);
    _myScore = min(_myScore + 1, maxScore);
  }

  /// increment opponent score limit by MAX_SCORE
  void addOpponentScore() async {
    await FlameAudio.play(crashFile);
    _oppoScore = min(_oppoScore + 1, maxScore);
  }

  /// end the game
  /// * play victory or defeat music
  /// * nicely end net games if needed
  /// * set mode to game over
  /// * show main menu
  void endGame() async {
    lock.synchronized(() async {
      if (isOver) return;

      if (myScore >= maxScore) {
        await FlameAudio.play(victoryFile);
      } else if (_oppoScore >= maxScore) {
        await FlameAudio.play(wahFile);
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
        log.info("Received first msg from guest, starting game as host...");
        _netSvc!.stopBroadcasting();
        overlays.remove(hostWaitingOverlayKey);
        _mode = GameMode.host;
        _receiveCount = data.count;
        //ball.reset(normVY: Ball.normSpeed, normX: .5, normY: .5);
        await FlameAudio.play(whistleFile);
        await _music.stop();
        await _music.play(playFile);
      } else if (ball.vy == 0 && data.bvy != 0) {
        log.info("Guest just got the first update from host...");
        _receiveCount = data.count;
      } else if (data.count < _receiveCount) {
        log.warning("Received data count ${data.count} less than last "
            "received count $_receiveCount, ignored...");
        return;
      } else if (_lastReceiveTime.isBefore(ball.lastHitTime.add(hitWait))) {
        log.warning("Received data less than last hit time + wait, ignored...");
        return;
      }

      _receiveCount = data.count;
      oppoPad.setOpponentPos(_pxMap.toDevX(1.0 - data.px));

      if (data.by > 0.8 && data.bvy < 0 && ball.vy < 0) {
        // ball Y direction changed, opponent must have detected hit, play Pop
        FlameAudio.play(popFile);
      }

      if (isGuest) {
        // let host update my ball state
        ball.updateOnReceive(
          data.bx,
          data.by,
          data.bvx,
          data.bvy,
          data.pause,
        );
        if (myScore < data.oppoScore || oppoScore < data.myScore) {
          // score changed, host must have detected crashed, play Crash
          FlameAudio.play(crashFile);
          _myScore = data.oppoScore;
          _oppoScore = data.myScore;

          if (_oppoScore >= maxScore || _myScore >= maxScore) {
            endGame();
          }
        }
      }
    });
  }

  /// send game state update to opponent
  void _sendStateUpdate() async {
    lock.synchronized(() async {
      final data = GameNetData(
        _netSvc!.gameID,
        _sendCount++,
        _pxMap.toNormX(myPad.x),
        _pxMap.toNormX(ball.x),
        _pxMap.toNormY(ball.y),
        _pxMap.toNormWth(ball.vx),
        _pxMap.toNormHgt(ball.vy),
        ball.pause,
        myScore,
        oppoScore,
        _netSvc!.myName,
      );
      _netSvc!.send(data);
    });
  }

  /// update by detecting if game is over, and send network update if needed
  @override
  void update(double dt) async {
    super.update(dt);
    bool gameIsOver = false;
    if (myScore >= maxScore) {
      gameIsOver = true;
      _gameMsg = "You've Won!";
    } else if (oppoScore >= maxScore) {
      gameIsOver = true;
      _gameMsg = "You've Lost!";
    } else if (isHost || isGuest) {
      final waitLimit = _lastReceiveTime.add(maxNetWait);
      if (clock.now().isAfter(waitLimit)) {
        gameIsOver = true;
        _gameMsg = "Connection Interrupted.";
      }
    }

    if (isHost || isGuest) {
      _sinceLastSent += dt;

      /// use max send to limit num of sends
      if (_sinceLastSent >= maxSendGap || ball.forceNetSend) {
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
      modeMsg = "Host:${_netSvc!.myName} vs ${_netSvc!.oppoName}";
    } else if (isGuest) {
      modeMsg = "${_netSvc!.myName} vs Host:${_netSvc!.oppoName}";
    } else {
      modeMsg = "";
    }

    if (modeMsg.isNotEmpty) {
      _txtPaint.render(
        canvas,
        modeMsg,
        _pxMap.toDevPos(1, 0),
        anchor: Anchor.topRight,
      );
    }

    super.render(canvas);
  }
}

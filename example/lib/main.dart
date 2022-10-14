import 'dart:async';
import 'dart:io';

import 'package:camerawesome/models/orientations.dart';
import 'package:camerawesome_example/widgets/bottom_bar.dart';
import 'package:camerawesome_example/widgets/camera_preview.dart';
import 'package:camerawesome_example/widgets/preview_card.dart';
import 'package:camerawesome_example/widgets/top_bar.dart';
import 'package:exif/exif.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:image/image.dart' as imgUtils;

import 'package:path_provider/path_provider.dart';
import 'package:camerawesome/camerawesome_plugin.dart';
import 'package:rxdart/rxdart.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  runApp(MaterialApp(home: MyApp(), debugShowCheckedModeBanner: false));
}

class MyApp extends StatefulWidget {
  // just for E2E test. if true we create our images names from datetime.
  // Else it's just a name to assert image exists
  final bool randomPhotoName;

  MyApp({this.randomPhotoName = true});

  @override
  _MyAppState createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with TickerProviderStateMixin {
  String? _lastPhotoPath, _lastVideoPath;
  bool _focus = false, _fullscreen = true, _isRecordingVideo = false;

  ValueNotifier<CameraFlashes> _switchFlash = ValueNotifier(CameraFlashes.NONE);
  ValueNotifier<double> _zoomNotifier = ValueNotifier(0);
  ValueNotifier<bool> _enablePinchToZoom = ValueNotifier(true);
  ValueNotifier<Size?> _photoSize = ValueNotifier(null);
  ValueNotifier<Sensors> _sensor = ValueNotifier(Sensors.BACK);
  ValueNotifier<CaptureModes> _captureMode = ValueNotifier(CaptureModes.PHOTO);
  ValueNotifier<bool> _enableAudio = ValueNotifier(true);
  ValueNotifier<CameraOrientations> _orientation =
      ValueNotifier(CameraOrientations.PORTRAIT_UP);
  ValueNotifier<bool> _recordingPaused = ValueNotifier(false);
  ValueNotifier<double> _brightnessCorrection = ValueNotifier(0);

  /// use this to call a take picture
  PictureController _pictureController = PictureController();

  /// use this to record a video
  VideoController _videoController = VideoController();

  /// list of available sizes
  List<Size>? _availableSizes;

  late AnimationController _iconsAnimationController,
      _previewAnimationController;
  late Animation<Offset> _previewAnimation;
  Timer? _previewDismissTimer;
  // StreamSubscription<Uint8List> previewStreamSub;
  Stream<Uint8List>? previewStream;

  ExifPreferences _exifPreferences = ExifPreferences(
    saveGPSLocation: false,
  );
  StreamSubscription? _previewStreamSubscription;

  @override
  void initState() {
    super.initState();
    _iconsAnimationController = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 300),
    );

    _previewAnimationController = AnimationController(
      duration: const Duration(milliseconds: 1300),
      vsync: this,
    );
    _previewAnimation = Tween<Offset>(
      begin: const Offset(-2.0, 0.0),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(
        parent: _previewAnimationController,
        curve: Curves.elasticOut,
        reverseCurve: Curves.elasticIn,
      ),
    );
  }

  @override
  void dispose() {
    _iconsAnimationController.dispose();
    _previewAnimationController.dispose();
    _brightnessCorrection.dispose();
    // previewStreamSub.cancel();
    _photoSize.dispose();
    _captureMode.dispose();
    _previewStreamSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          this._fullscreen ? buildFullScreenCamera() : buildSizedScreenCamera(),
          _buildInterface(),
          (!_isRecordingVideo)
              ? PreviewCardWidget(
                  lastPhotoPath: _lastPhotoPath,
                  orientation: _orientation,
                  previewAnimation: _previewAnimation,
                )
              : Container(),
        ],
      ),
    );
  }

  Widget _buildInterface() {
    return Stack(
      children: <Widget>[
        SafeArea(
          bottom: false,
          child: TopBarWidget(
            isFullscreen: _fullscreen,
            isRecording: _isRecordingVideo,
            enableAudio: _enableAudio,
            photoSize: _photoSize,
            enablePinchToZoom: _enablePinchToZoom,
            pausedRecording: _recordingPaused,
            captureMode: _captureMode,
            switchFlash: _switchFlash,
            orientation: _orientation,
            rotationController: _iconsAnimationController,
            exifPreferences: _exifPreferences,
            onSetExifPreferences: (newExifData) {
              _pictureController.setExifPreferences(newExifData);
              setState(() {});
            },
            onFlashTap: () {
              switch (_switchFlash.value) {
                case CameraFlashes.NONE:
                  _switchFlash.value = CameraFlashes.ON;
                  break;
                case CameraFlashes.ON:
                  _switchFlash.value = CameraFlashes.AUTO;
                  break;
                case CameraFlashes.AUTO:
                  _switchFlash.value = CameraFlashes.ALWAYS;
                  break;
                case CameraFlashes.ALWAYS:
                  _switchFlash.value = CameraFlashes.NONE;
                  break;
              }
              setState(() {});
            },
            onPinchToZoomChange: () {
              this._enablePinchToZoom.value = !this._enablePinchToZoom.value;
              setState(() {});
            },
            onAudioChange: () {
              this._enableAudio.value = !this._enableAudio.value;
              setState(() {});
            },
            onChangeSensorTap: () {
              this._focus = !_focus;
              if (_sensor.value == Sensors.FRONT) {
                _sensor.value = Sensors.BACK;
              } else {
                _sensor.value = Sensors.FRONT;
              }
            },
            onResolutionTap: () => _buildChangeResolutionDialog(),
            onFullscreenTap: () {
              this._fullscreen = !this._fullscreen;
              setState(() {});
            },
            onPausedRecordingChange: _isRecordingVideo
                ? () {
                    if (_recordingPaused.value == true) {
                      _recordingPaused.value = false;
                    } else {
                      _recordingPaused.value = true;
                    }
                    setState(() {});
                  }
                : null,
          ),
        ),
        BottomBarWidget(
          onZoomInTap: () {
            if (_zoomNotifier.value <= 0.9) {
              _zoomNotifier.value += 0.1;
            }
            setState(() {});
          },
          onZoomOutTap: () {
            if (_zoomNotifier.value >= 0.1) {
              _zoomNotifier.value -= 0.1;
            }
            setState(() {});
          },
          onCaptureModeSwitchChange: () {
            if (_captureMode.value == CaptureModes.PHOTO) {
              _captureMode.value = CaptureModes.VIDEO;
            } else {
              _captureMode.value = CaptureModes.PHOTO;
            }
            setState(() {});
          },
          onCaptureTap: (_captureMode.value == CaptureModes.PHOTO)
              ? _takePhoto
              : _recordVideo,
          rotationController: _iconsAnimationController,
          orientation: _orientation,
          isRecording: _isRecordingVideo,
          captureMode: _captureMode,
        ),
        _buildLeftManualBrightness(),
      ],
    );
  }

  _takePhoto() async {
    // lets just make our phone vibrate
    HapticFeedback.mediumImpact();

    final Directory extDir = await getTemporaryDirectory();
    final testDir =
        await Directory('${extDir.path}/test').create(recursive: true);
    final String filePath = widget.randomPhotoName
        ? '${testDir.path}/${DateTime.now().millisecondsSinceEpoch}.jpg'
        : '${testDir.path}/photo_test.jpg';
    await _pictureController.takePicture(filePath);
    final file = File(filePath);
    // precache the image before display it
    await precacheImage(FileImage(file), context);
    _lastPhotoPath = filePath;
    setState(() {});
    if (_previewAnimationController.status == AnimationStatus.completed) {
      _previewAnimationController.reset();
    }
    _previewAnimationController.forward();
    final bytes = file.readAsBytesSync();
    print("----------------------------------");
    print("TAKE PHOTO CALLED");
    print("==> hastakePhoto : ${await file.exists()} | path : $filePath");
    final img = imgUtils.decodeImage(bytes);
    print("==> img.width : ${img?.width} | img.height : ${img?.height}");
    final exifData = await readExifFromBytes(bytes);
    for (var exif in exifData.entries) {
      print("==> exifData : ${exif.key} : ${exif.value}");
    }

    print("----------------------------------");
  }

  _recordVideo() async {
    // lets just make our phone vibrate
    HapticFeedback.mediumImpact();

    if (this._isRecordingVideo) {
      await _videoController.stopRecordingVideo();

      _isRecordingVideo = false;
      setState(() {});

      final file = File(_lastVideoPath!);
      print("----------------------------------");
      print("VIDEO RECORDED");
      print(
          "==> has been recorded : ${file.exists()} | path : $_lastVideoPath");
      print("----------------------------------");

      await Future.delayed(Duration(milliseconds: 300));
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => CameraPreview(
            videoPath: _lastVideoPath!,
          ),
        ),
      );
    } else {
      final Directory extDir = await getTemporaryDirectory();
      final testDir =
          await Directory('${extDir.path}/test').create(recursive: true);
      final String filePath = widget.randomPhotoName
          ? '${testDir.path}/${DateTime.now().millisecondsSinceEpoch}.mp4'
          : '${testDir.path}/video_test.mp4';
      await _videoController.recordVideo(filePath);
      _isRecordingVideo = true;
      _lastVideoPath = filePath;
      setState(() {});
    }
  }

  _buildChangeResolutionDialog() {
    showModalBottomSheet(
      context: context,
      builder: (context) => ListView.separated(
        itemBuilder: (context, index) => ListTile(
          key: ValueKey("resOption"),
          onTap: () {
            this._photoSize.value = _availableSizes?[index];
            setState(() {});
            Navigator.of(context).pop();
          },
          leading: Icon(Icons.aspect_ratio),
          title: Text(
              "${_availableSizes?[index].width}/${_availableSizes?[index].height}"),
        ),
        separatorBuilder: (context, index) => Divider(),
        itemCount: _availableSizes?.length ?? 0,
      ),
    );
  }

  _onOrientationChange(CameraOrientations newOrientation) {
    _orientation.value = newOrientation;
    if (_previewDismissTimer != null) {
      _previewDismissTimer!.cancel();
    }
  }

  _onPermissionsResult(bool granted) {
    // TODO This popup is displayed when we don't have the permissions, but it stays displayed even if we give
    // the permissions in the meantime
    if (!granted) {
      AlertDialog alert = AlertDialog(
        title: Text('Error'),
        content: Text(
            'It seems you doesn\'t authorized some permissions. Please check on your settings and try again.'),
        actions: [
          TextButton(
            child: Text('OK'),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      );

      // show the dialog
      showDialog(
        context: context,
        builder: (BuildContext context) {
          return alert;
        },
      );
    } else {
      setState(() {});
      print("granted");
    }
  }

  Widget _buildLeftManualBrightness() {
    return Positioned(
      left: 32,
      bottom: 300,
      child: RotatedBox(
        quarterTurns: -1,
        child: SliderTheme(
          data: SliderThemeData(
            trackHeight: 10,
            inactiveTrackColor: Colors.white70,
          ),
          child: Slider(
            value: _brightnessCorrection.value,
            min: 0,
            max: 1,
            divisions: 10,
            label: _brightnessCorrection.value.toStringAsFixed(2),
            onChanged: (double value) =>
                setState(() => _brightnessCorrection.value = value),
          ),
        ),
      ),
    );
  }

  Widget buildFullScreenCamera() {
    return Positioned(
      top: 0,
      left: 0,
      bottom: 0,
      right: 0,
      child: Center(
        child: CameraAwesome(
          onPermissionsResult: _onPermissionsResult,
          selectDefaultSize: (availableSizes) {
            this._availableSizes = availableSizes;
            return availableSizes[0];
          },
          exifPreferences: _exifPreferences,
          captureMode: _captureMode,
          photoSize: _photoSize,
          sensor: _sensor,
          enableAudio: _enableAudio,
          switchFlashMode: _switchFlash,
          zoom: _zoomNotifier,
          enablePinchToZoom: _enablePinchToZoom,
          onOrientationChanged: _onOrientationChange,
          brightness: _brightnessCorrection,
          imagesStreamBuilder: (imageStream) {
            // listen for images preview stream
            // you can use it to process AI recognition or anything else...
            _previewStreamSubscription?.cancel();
            _previewStreamSubscription = imageStream
                // use bufferTime to only analyze images every 1500 ms
                ?.bufferTime(Duration(milliseconds: 1500))
                .listen(_previewStreamHandler);
          },
          onCameraStarted: () {
            // camera started here -- do your after start stuff
          },
          recordingPaused: _recordingPaused,
        ),
      ),
    );
  }

  Widget buildSizedScreenCamera() {
    return Positioned(
      top: 0,
      left: 0,
      bottom: 0,
      right: 0,
      child: Container(
        color: Colors.black,
        child: Center(
          child: Container(
            height: 300,
            width: MediaQuery.of(context).size.width,
            child: CameraAwesome(
              onPermissionsResult: _onPermissionsResult,
              selectDefaultSize: (availableSizes) {
                this._availableSizes = availableSizes;
                return availableSizes[0];
              },
              exifPreferences: _exifPreferences,
              captureMode: _captureMode,
              photoSize: _photoSize,
              sensor: _sensor,
              fitted: true,
              switchFlashMode: _switchFlash,
              enablePinchToZoom: _enablePinchToZoom,
              zoom: _zoomNotifier,
              onOrientationChanged: _onOrientationChange,
              brightness: _brightnessCorrection,
              recordingPaused: _recordingPaused,
              imagesStreamBuilder: (imageStream) {
                // listen for images preview stream
                // you can use it to process AI recognition or anything else...
                _previewStreamSubscription?.cancel();
                _previewStreamSubscription = imageStream
                    // use bufferTime to only analyze images every 1500 ms
                    ?.bufferTime(Duration(milliseconds: 1500))
                    .listen(_previewStreamHandler);
              },
            ),
          ),
        ),
      ),
    );
  }

  void _previewStreamHandler(List<Uint8List> data) async {
    // In this example, we will handle only the last event
    final dir = await getTemporaryDirectory();
    final file =
        File("${dir.path}/test/${DateTime.now().millisecondsSinceEpoch}.jpg");
    await file.writeAsBytes(data.last);

    final List<BarcodeFormat> formats = [BarcodeFormat.all];
    final barcodeScanner = BarcodeScanner(formats: formats);
    List<Barcode> barcodesData =
        await barcodeScanner.processImage(InputImage.fromFile(file));
    List<String> barcodes = [];
    for (var b in barcodesData) {
      barcodes.add(b.rawValue.toString());
    }
    // For this example, we only check if the first barcode detected is an url
    // and propose to open it
    if (barcodes.isNotEmpty && Uri.parse(barcodes.first).isAbsolute) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Open ${barcodes.first} ?"),
          action: SnackBarAction(
              label: "GO",
              onPressed: () {
                launchUrl(Uri.parse(barcodes.first));
              }),
        ),
      );
    }
  }
}

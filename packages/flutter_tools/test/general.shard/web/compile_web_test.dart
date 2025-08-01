// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/build_system/build_system.dart';
import 'package:flutter_tools/src/build_system/targets/web.dart';
import 'package:flutter_tools/src/dart/pub.dart';
import 'package:flutter_tools/src/project.dart';
import 'package:flutter_tools/src/reporting/reporting.dart';
import 'package:flutter_tools/src/web/compile.dart';
import 'package:flutter_tools/src/web/file_generators/flutter_service_worker_js.dart';
import 'package:unified_analytics/unified_analytics.dart';

import '../../src/common.dart';
import '../../src/context.dart';
import '../../src/fakes.dart';
import '../../src/package_config.dart';
import '../../src/test_build_system.dart';
import '../../src/throwing_pub.dart';

void main() {
  late MemoryFileSystem fileSystem;
  late TestUsage testUsage;
  late FakeAnalytics fakeAnalytics;
  late BufferLogger logger;
  late FakeFlutterVersion flutterVersion;
  late FlutterProject flutterProject;

  setUp(() {
    fileSystem = MemoryFileSystem.test();
    testUsage = TestUsage();
    logger = BufferLogger.test();
    flutterVersion = FakeFlutterVersion(frameworkVersion: '1.0.0', engineRevision: '9.8.7');
    fakeAnalytics = getInitializedFakeAnalyticsInstance(
      fs: fileSystem,
      fakeFlutterVersion: flutterVersion,
    );
    fileSystem.currentDirectory.childFile('pubspec.yaml')
      ..createSync(recursive: true)
      ..writeAsStringSync('''
name: my_app
environement:
  sdk: '^3.5.0'
''');

    flutterProject = FlutterProject.fromDirectoryTest(fileSystem.currentDirectory);
    writePackageConfigFiles(directory: flutterProject.directory, mainLibName: 'my_app');
  });

  testUsingContext(
    'WebBuilder sets environment on success',
    () async {
      final buildSystem = TestBuildSystem.all(BuildResult(success: true), (
        Target target,
        Environment environment,
      ) {
        expect(target, isA<WebServiceWorker>());
        expect(environment.defines, <String, String>{
          'TargetFile': 'target',
          'HasWebPlugins': 'false',
          'ServiceWorkerStrategy': ServiceWorkerStrategy.offlineFirst.cliName,
          'BuildMode': 'debug',
          'DartObfuscation': 'false',
          'TrackWidgetCreation': 'true',
          'TreeShakeIcons': 'false',
        });

        expect(environment.engineVersion, '9.8.7');
        expect(environment.generateDartPluginRegistry, isFalse);
      });

      final webBuilder = WebBuilder(
        logger: logger,
        processManager: FakeProcessManager.any(),
        buildSystem: buildSystem,
        flutterVersion: flutterVersion,
        fileSystem: fileSystem,
        analytics: fakeAnalytics,
      );
      await webBuilder.buildWeb(
        flutterProject,
        'target',
        BuildInfo.debug,
        ServiceWorkerStrategy.offlineFirst,
        compilerConfigs: <WebCompilerConfig>[
          const WasmCompilerConfig(optimizationLevel: 0, stripWasm: false),
          const JsCompilerConfig.run(
            nativeNullAssertions: true,
            renderer: WebRendererMode.canvaskit,
          ),
        ],
      );

      expect(logger.statusText, contains('Compiling target for the Web...'));
      expect(logger.errorText, isEmpty);
      // Runs ScrubGeneratedPluginRegistrant migrator.
      expect(logger.traceText, contains('generated_plugin_registrant.dart not found. Skipping.'));

      expect(
        fakeAnalytics.sentEvents,
        containsAll(<Event>[
          Event.flutterBuildInfo(
            label: 'web-compile',
            buildType: 'web',
            settings:
                'dryRun: false; optimizationLevel: 0; web-renderer: skwasm,canvaskit; web-target: wasm,js;',
          ),
        ]),
      );

      expect(
        analyticsTimingEventExists(
          sentEvents: fakeAnalytics.sentEvents,
          workflow: 'build',
          variableName: 'dual-compile',
        ),
        true,
      );
    },
    overrides: <Type, Generator>{
      ProcessManager: () => FakeProcessManager.any(),
      Pub: ThrowingPub.new,
    },
  );

  testUsingContext(
    'WebBuilder throws tool exit on failure',
    () async {
      final buildSystem = TestBuildSystem.all(
        BuildResult(
          success: false,
          exceptions: <String, ExceptionMeasurement>{
            'hello': ExceptionMeasurement(
              'hello',
              const FormatException('illegal character in input string'),
              StackTrace.current,
            ),
          },
        ),
      );

      final webBuilder = WebBuilder(
        logger: logger,
        processManager: FakeProcessManager.any(),
        buildSystem: buildSystem,
        flutterVersion: flutterVersion,
        fileSystem: fileSystem,
        analytics: fakeAnalytics,
      );
      await expectLater(
        () async => webBuilder.buildWeb(
          flutterProject,
          'target',
          BuildInfo.debug,
          ServiceWorkerStrategy.offlineFirst,
          compilerConfigs: <WebCompilerConfig>[
            const JsCompilerConfig.run(
              nativeNullAssertions: true,
              renderer: WebRendererMode.canvaskit,
            ),
          ],
        ),
        throwsToolExit(message: 'Failed to compile application for the Web.'),
      );

      expect(
        logger.errorText,
        contains('Target hello failed: FormatException: illegal character in input string'),
      );
      expect(testUsage.timings, isEmpty);
      expect(fakeAnalytics.sentEvents, isEmpty);
    },
    overrides: <Type, Generator>{
      ProcessManager: () => FakeProcessManager.any(),
      Pub: ThrowingPub.new,
    },
  );

  Future<void> testRendererModeFromDartDefines(WebRendererMode webRenderer) async {
    testUsingContext(
      'WebRendererMode.${webRenderer.name} can be initialized from dart defines',
      () {
        final computed = WebRendererMode.fromDartDefines(webRenderer.dartDefines, useWasm: true);

        expect(computed, webRenderer);
      },
      overrides: <Type, Generator>{ProcessManager: () => FakeProcessManager.any()},
    );
  }

  WebRendererMode.values.forEach(testRendererModeFromDartDefines);

  testUsingContext(
    'WebRendererMode.fromDartDefines sets a wasm-aware default for unknown dart defines.',
    () async {
      var computed = WebRendererMode.fromDartDefines(<String>{}, useWasm: false);
      expect(computed, WebRendererMode.getDefault(useWasm: false));

      computed = WebRendererMode.fromDartDefines(<String>{}, useWasm: true);
      expect(computed, WebRendererMode.getDefault(useWasm: true));
    },
  );
}

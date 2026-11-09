"""Check Apple configuration before allocating a macOS runner."""
import importlib.util
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('apple_ci', Path(__file__).with_name('apple-ci.py'))
ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci)


class AppleConfigurationTest(unittest.TestCase):
    def test_bootstrap_uses_fresh_download_url_without_changing_checksum(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / 'scripts'
            (scripts / 'cmake').mkdir(parents=True)
            bootstrap = 'vcpkgDownloadFile "https://github.com/microsoft/vcpkg-tool/releases/download/$VCPKG_TOOL_RELEASE_TAG/$vcpkgToolName" "$vcpkgRootDir/vcpkg" $vcpkgToolReleaseSha\n'
            (scripts / 'bootstrap.sh').write_text(bootstrap)
            (scripts / 'cmake/vcpkg_from_github.cmake').write_text('"${github_host}/${org_name}/${repo_name}/archive/${ref_to_use}.tar.gz"')
            (scripts / 'cmake/vcpkg_download_distfile.cmake').write_text('    # SILENT_EXIT and QUIET are meaningless')
            ci.configure_downloads(root)
            first = (scripts / 'bootstrap.sh').read_text()
            ci.configure_downloads(root)
            self.assertEqual(first, (scripts / 'bootstrap.sh').read_text())
            self.assertIn('?nnu-build=${NNU_VCPKG_DOWNLOAD_NONCE:-0}', first)
            self.assertTrue(first.endswith('"$vcpkgRootDir/vcpkg" $vcpkgToolReleaseSha\n'))

    def test_platform_configuration_keeps_ios_and_macos_separate(self):
        files = ['Cargo.toml', 'build.py', 'res/nnu/official-support-public-keys.txt',
                 'flutter/ios/Runner.xcodeproj/project.pbxproj', 'flutter/ios/Runner/Info.plist',
                 'flutter/macos/Runner.xcodeproj/project.pbxproj', 'flutter/macos/Podfile']
        originals = {name: (ci.ROOT / name).read_bytes() for name in files}
        for platform, arch in [('ios', 'arm64'), ('macos', 'arm64'), ('macos', 'x86_64')]:
            with self.subTest(platform=platform, arch=arch), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                for name in files:
                    target = root / name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(originals[name])
                env = dict(APPLE_PLATFORM=platform, APPLE_ARCH=arch, GITHUB_ENV=str(root / 'env'))
                with patch.object(ci, 'ROOT', root), patch.dict(os.environ, env):
                    ci.configure()
                if platform == 'ios':
                    project = (root / files[3]).read_text()
                    self.assertIn('cn.nnu.rustdesk', project)
                    self.assertNotIn('DT_TOOLCHAIN_DIR', project)
                    self.assertNotIn('DEVELOPMENT_TEAM = HZF9JMC8YN;', project)
                    self.assertIn('IPHONEOS_DEPLOYMENT_TARGET = 15.0;', project)
                    self.assertEqual((root / 'build.py').read_bytes(), originals['build.py'])
                elif arch == 'arm64':
                    self.assertIn('MACOSX_DEPLOYMENT_TARGET=12.3', (root / 'build.py').read_text())
                    self.assertIn("platform :osx, '12.3'", (root / 'flutter/macos/Podfile').read_text())
                    self.assertEqual((root / files[3]).read_bytes(), originals[files[3]])
                else:
                    self.assertEqual((root / 'build.py').read_bytes(), originals['build.py'])
                if platform == 'macos':
                    self.assertNotIn('DEVELOPMENT_TEAM = HZF9JMC8YN;',
                                     (root / 'flutter/macos/Runner.xcodeproj/project.pbxproj').read_text())
        self.assertEqual({name: (ci.ROOT / name).read_bytes() for name in files}, originals)

    def test_native_validation_rejects_cross_platform_cached_objects(self):
        for platform, output in [('macos', 'platform 1\n'), ('macos', 'platform MACOS\n'),
                                 ('macos', 'cmd LC_VERSION_MIN_MACOSX\n'), ('ios', 'platform 2\n')]:
            env = dict(APPLE_PLATFORM=platform, VCPKG_DEFAULT_TRIPLET='fixture', VCPKG_ROOT='/fixture')
            with patch.dict(os.environ, env), patch.object(ci.subprocess, 'run', return_value=SimpleNamespace(stdout=output)):
                ci.check_native()
        env = dict(APPLE_PLATFORM='macos', VCPKG_DEFAULT_TRIPLET='fixture', VCPKG_ROOT='/fixture')
        for output in ['platform 2\n', 'platform 1\nplatform 2\n', '']:
            with patch.dict(os.environ, env), patch.object(ci.subprocess, 'run', return_value=SimpleNamespace(stdout=output)):
                with self.assertRaises(ValueError):
                    ci.check_native()


if __name__ == '__main__':
    unittest.main()

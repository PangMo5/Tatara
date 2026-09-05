#!/usr/bin/env python3
import argparse
import hashlib
import re
from pathlib import Path

root = Path(__file__).resolve().parent.parent
version = re.search(r'^let appVersion = "([^"]+)"$', (root / 'Project.swift').read_text(), re.M)[1]
p = argparse.ArgumentParser()
p.add_argument('artifacts', type=Path)
p.add_argument('output', type=Path)
a = p.parse_args()
def digest(arch):
    return hashlib.sha256((a.artifacts / f'tatara-{version}-{arch}-apple-darwin.tar.gz').read_bytes()).hexdigest()
formula = f'''class Tatara < Formula
  desc "Structural code review workspace for your terminal"
  homepage "https://github.com/PangMo5/Tatara"
  version "{version}"
  license "AGPL-3.0-only"

  on_macos do
    on_arm do
      url "https://github.com/PangMo5/Tatara/releases/download/v{version}/tatara-{version}-aarch64-apple-darwin.tar.gz"
      sha256 "{digest('aarch64')}"
    end
    on_intel do
      url "https://github.com/PangMo5/Tatara/releases/download/v{version}/tatara-{version}-x86_64-apple-darwin.tar.gz"
      sha256 "{digest('x86_64')}"
    end
  end

  depends_on macos: :sequoia
  depends_on "difftastic"
  depends_on "gh"

  def install
    bin.install "bin/tatara"
    (share/"tatara").install Dir["share/tatara/*"]
  end

  test do
    assert_equal version.to_s, shell_output("#{{bin}}/tatara --version").strip
  end
end
'''
a.output.parent.mkdir(parents=True, exist_ok=True)
a.output.write_text(formula)

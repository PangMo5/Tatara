#!/usr/bin/env python3
"""Exercise the built application in a real PTY; never submit a remote review."""
import argparse
import codecs
import fcntl
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import termios
import time
import pyte

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('binary', type=Path)
parser.add_argument('--repo')
args = parser.parse_args()
artifacts = root / '.artifacts/pty'
artifacts.mkdir(parents=True, exist_ok=True)

class Terminal:
    def __init__(self, extra, width=140, height=38):
        self.master, slave = pty.openpty()
        self.width, self.height = width, height
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', height, width, 0, 0))
        env = dict(os.environ, TERM='xterm-256color', COLORTERM='truecolor')
        env.pop('NO_COLOR', None)
        self.process = subprocess.Popen([str(args.binary.resolve()), '--stable-output', '--force-color', *extra], stdin=slave, stdout=slave, stderr=slave, env=env, start_new_session=True)
        os.close(slave)
        self.screen = pyte.Screen(width, height)
        self.stream = pyte.Stream(self.screen)
        self.decoder = codecs.getincrementaldecoder('utf-8')('replace')
        self.raw = bytearray()
    @property
    def text(self):
        return '\n'.join(self.screen.display)
    def read(self, duration=.2):
        end = time.monotonic() + duration
        while time.monotonic() < end:
            ready, _, _ = select.select([self.master], [], [], max(0, end-time.monotonic()))
            if ready:
                try: chunk = os.read(self.master, 65536)
                except OSError: return
                if not chunk: return
                self.raw.extend(chunk)
                self.stream.feed(self.decoder.decode(chunk))
    def wait(self, text, timeout=20):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            self.read()
            if text in self.text: return
            if self.process.poll() is not None: break
        raise AssertionError(f'Missing {text!r}\n{self.text}')
    def send(self, data):
        os.write(self.master, data.encode())
        self.read(.3)
    def snapshot(self, name):
        self.read(.3)
        (artifacts / f'{name}.txt').write_text(self.text)
        (artifacts / f'{name}.ansi').write_bytes(self.raw)
    def finish(self):
        deadline = time.monotonic() + 8
        while self.process.poll() is None and time.monotonic() < deadline:
            self.read(.2)
        self.snapshot('exit-state')
        assert self.process.poll() is not None, f'Application did not exit:\n{self.text}'
    def close(self):
        if self.process.poll() is None:
            os.killpg(self.process.pid, signal.SIGINT)
            self.read(.3)
            try: self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait()
        os.close(self.master)

if args.repo:
    terminal = Terminal(['--repo', args.repo, '--language', 'en'])
    try:
        terminal.wait('1 · Pull requests')
        terminal.read(12)
        assert 'Could not load' not in terminal.text, terminal.text
        assert 'No open items.' not in terminal.text, terminal.text
        terminal.snapshot('live-overview')
        terminal.send(']')
        terminal.read(12)
        assert 'Could not load' not in terminal.text, terminal.text
        terminal.snapshot('live-diff')
        terminal.send('q')
        terminal.finish()
        assert terminal.process.returncode == 0
        print('Live GitHub read-only overview and diff passed.')
    finally: terminal.close()
else:
    terminal = Terminal(['--demo', '--language', 'en'])
    try:
        terminal.wait('Keep review navigation within bounds')
        terminal.snapshot('overview')
        terminal.send(']')
        terminal.wait('guard files.indices.contains')
        assert 'Could not load' not in terminal.text
        terminal.snapshot('diff-mocha')
        for theme in ['latte', 'frappe', 'macchiato', 'mocha']:
            terminal.send('T')
            terminal.wait(theme)
            terminal.wait('guard files.indices.contains')
            terminal.snapshot(f'diff-{theme}')
        terminal.send('?')
        terminal.wait('Write your review')
        terminal.send('j')
        terminal.snapshot('help')
        terminal.send('\x1b')
        terminal.wait('1 · Pull requests')
        assert '▸ #42' in terminal.text
        terminal.send('/q')
        terminal.wait('/q')
        assert terminal.process.poll() is None
        terminal.send('\x1b')
        terminal.send('I')
        terminal.wait('Remember the last reviewed file')
        terminal.snapshot('issues')
        terminal.send('I')
        terminal.wait('Sources/ReviewQueue.swift')
        terminal.send('R')
        terminal.wait('Write your review')
        terminal.snapshot('review')
        terminal.send('\x1b')
        terminal.wait('1 · Pull requests')
        terminal.send('c')
        terminal.wait('Choose a source line')
        terminal.snapshot('inline-comment')
        terminal.send('\x1b')
        terminal.wait('1 · Pull requests')
        terminal.snapshot('after-inline')
        terminal.send('q')
        terminal.snapshot('after-quit')
        terminal.finish()
        assert terminal.process.returncode == 0
        assert b'\x1b[?1049l' in terminal.raw, 'Alternate screen was not restored.'
    finally: terminal.close()
    for language, expected in [('en', 'Pull requests'), ('ko', 'PR'), ('ja', 'プルリクエスト'), ('zh-Hans', '拉取请求'), ('zh-Hant', '提取要求')]:
        terminal = Terminal(['--demo', '--language', language], width=90, height=28)
        try:
            terminal.wait(expected)
            terminal.wait('#42')
            terminal.snapshot(f'compact-{language}')
            terminal.send('q')
            terminal.finish()
            assert terminal.process.returncode == 0
        finally: terminal.close()
    terminal = Terminal(['--demo', '--language', 'en'], width=176, height=32)
    try:
        terminal.wait('Sources/ReviewQueue.swift')
        terminal.send(']')
        terminal.wait('guard files.indices.contains')
        terminal.snapshot('diff-wide')
        terminal.send('q')
        terminal.finish()
    finally: terminal.close()
    print('PTY: navigation, real difftastic, four flavors, search, issue switch, review composer, inline composer, five locales, compact layout and terminal restoration passed.')

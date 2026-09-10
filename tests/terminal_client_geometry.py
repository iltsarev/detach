#!/usr/bin/env python3
"""Размер управляемого окна при двух клиентах public attach на реальных PTY."""
import fcntl
import os
import pty
import select
import signal
import struct
import subprocess
import sys
import termios
import time


def main():
    tmux, socket, cli, session = sys.argv[1:]
    clients = []

    def tm(*args):
        return subprocess.check_output([tmux, '-S', socket, *args], timeout=3).decode().strip()

    def drain():
        descriptors = [fd for process, fd in clients if process.poll() is None]
        for fd in select.select(descriptors, [], [], 0.01)[0]:
            try:
                os.read(fd, 65536)
            except OSError:
                pass

    def wait_for(description, predicate):
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:
            if predicate():
                return
            drain()
        raise AssertionError(description + ': ' + tm('list-clients', '-F',
            '#{client_pid}|#{client_session}|#{client_width}x#{client_height}')
            + '; pane=' + tm('display-message', '-p', '-t', session, '#{pane_width}x#{pane_height}'))

    def resize(client, columns, rows):
        process, fd = client
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', rows, columns, 0, 0))
        os.kill(process.pid, signal.SIGWINCH)

    def attach(columns, rows, embedded):
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', rows, columns, 0, 0))
        args = [cli, 'codex', 'attach']
        if embedded:
            args += ['--terminal-features', 'sync']
        args += [session]
        environment = dict(os.environ, TERM='xterm-256color', LC_ALL='en_US.UTF-8')
        environment.pop('TMUX', None)
        process = subprocess.Popen(args, stdin=slave, stdout=slave, stderr=slave,
                                   env=environment, start_new_session=True)
        os.close(slave)
        client = (process, master)
        clients.append(client)
        wait_for('public attach registered', lambda: str(process.pid) in tm(
            'list-clients', '-F', '#{client_pid}').splitlines())
        return client

    def width_is(columns):
        return tm('display-message', '-p', '-t', session, '#{pane_width}') == str(columns)

    def activate(client, columns):
        # latest — последний активный клиент, а не минимальный размер обоих.
        os.write(client[1], b'x')
        wait_for('active client sets width ' + str(columns), lambda: width_is(columns))
        print('Активный клиент задаёт ширину', columns, flush=True)

    def close(client):
        process, fd = client
        process.terminate()
        try:
            # tmux пишет финальную очистку терминала при выходе. Как SwiftTerm,
            # продолжаем читать PTY, иначе tty drain может задержать завершение.
            wait_for('attach exits after TERM', lambda: process.poll() is not None)
        finally:
            os.close(fd)
            if process.poll() is None:
                process.kill()
            process.wait(timeout=3)
            clients.remove(client)

    try:
        policy = tm('show-options', '-A', '-wv', '-t', session, 'window-size')
        assert policy == 'latest', repr(policy)
        provider = tm('display-message', '-p', '-t', session, '#{pane_pid}')
        embedded = attach(132, 42, True)
        wait_for('embedded width', lambda: width_is(132))
        external = attach(78, 28, False)
        activate(external, 78)
        activate(embedded, 132)
        resize(embedded, 154, 46)
        activate(embedded, 154)
        activate(external, 78)
        close(external)
        wait_for('external close restores embedded width', lambda: width_is(154))
        close(embedded)
        assert tm('display-message', '-p', '-t', session, '#{pane_pid}') == provider
        assert tm('display-message', '-p', '-t', session, '#{pane_dead}') == '0'
        assert not tm('list-clients', '-t', session, '-F', '#{client_pid}')
        print('Два клиента, resize и закрытие обоих: PASS; provider pane сохранился', flush=True)
    finally:
        for client in clients[:]:
            close(client)


if __name__ == '__main__':
    main()

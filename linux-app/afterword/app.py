"""The Qt (PySide6) desktop app. One window: session list + detail, a recording
dialog, a settings dialog. Talks to server.py."""
from __future__ import annotations

import subprocess
import sys
import time
from pathlib import Path

from PySide6.QtCore import Qt, QThread, QTimer, QUrl, Signal
from PySide6.QtGui import QAction, QKeySequence
from PySide6.QtMultimedia import QAudioOutput, QMediaPlayer
from PySide6.QtWidgets import (QApplication, QCheckBox, QComboBox, QDialog,
                               QDialogButtonBox, QFileDialog, QFormLayout,
                               QHBoxLayout, QInputDialog, QLabel, QLineEdit,
                               QListWidget, QListWidgetItem, QMainWindow, QMenu,
                               QMessageBox, QPlainTextEdit, QPushButton, QSizePolicy,
                               QSlider, QSpinBox, QSplitter, QTabWidget,
                               QTextBrowser, QToolButton, QVBoxLayout, QWidget)

from .core import (ApiError, Config, ScribeAPI, Segment, Session, STATUS_BUSY,
                   all_sessions, delete_session, load_session)
from .recorder import Recorder, default_monitor, have_ffmpeg, sources

POLL_MS = 5000


def mmss(t: float) -> str:
    t = int(t or 0)
    return f"{t // 60}:{t % 60:02d}"


# --------------------------------------------------------------------------- workers

class TranscribeThread(QThread):
    updated = Signal(str)          # session id
    failed = Signal(str, str)      # session id, message

    def __init__(self, cfg: Config, sid: str):
        super().__init__()
        self.cfg, self.sid = cfg, sid

    def run(self) -> None:
        api = ScribeAPI.from_config(self.cfg)
        s = load_session(self.sid)
        if not s:
            return
        try:
            voices = [v.get("name", "") for v in api.voices()]
            if not s.server_job_id:
                created = api.submit(
                    audio=s.audio_path,
                    system_audio=s.system_path if s.has_system_audio else None,
                    kind=s.kind, title=s.title, language=str(self.cfg["language"]),
                    summary_model=str(self.cfg["summary_model"]),
                    ollama_url=self.cfg.ollama_override,
                    speaker_count=s.speaker_count,
                    vocab=self.cfg.vocab_hint(voices))
                s.server_job_id = created["id"]
                s.status = "processing"
                s.save()
                self.updated.emit(s.id)

            while not self.isInterruptionRequested():
                for _ in range(8):
                    if self.isInterruptionRequested():
                        return
                    time.sleep(0.5)
                job = api.job(s.server_job_id)
                st = job.get("status")
                if st in ("transcribed", "done"):
                    s = load_session(self.sid) or s
                    s.transcript_md = job.get("transcript_md")
                    s.summary_md = job.get("summary_md")
                    s.segments = [Segment(x.get("start"), x.get("end"),
                                          (x.get("text") or "").strip(), x.get("speaker"))
                                  for x in (job.get("segments") or [])]
                    s.speakers = job.get("speakers_detected") or []
                    s.language = job.get("detected_language")
                    if not s.speaker_names and job.get("auto_speakers"):
                        s.speaker_names = dict(job["auto_speakers"])
                    s.status = st
                    if st == "done":
                        s.error = None
                    s.save()
                    self.updated.emit(s.id)
                    if st == "done":
                        return
                elif st == "error":
                    s = load_session(self.sid) or s
                    s.status = "error"
                    s.error = job.get("error") or "Unbekannter Serverfehler"
                    s.save()
                    self.failed.emit(s.id, s.error)
                    return
        except ApiError as e:
            if e.status and 400 <= e.status < 500:
                s.status = "error"; s.error = str(e); s.save()
                self.failed.emit(s.id, str(e))
            else:
                self.failed.emit(s.id, f"{e} — versuche es später erneut")


class ResummarizeThread(QThread):
    updated = Signal(str)
    failed = Signal(str, str)

    def __init__(self, cfg: Config, sid: str):
        super().__init__()
        self.cfg, self.sid = cfg, sid

    def run(self) -> None:
        s = load_session(self.sid)
        if not s or not s.server_job_id:
            return
        try:
            md = ScribeAPI.from_config(self.cfg).resummarize(
                s.server_job_id, s.speaker_names,
                str(self.cfg["summary_model"]), self.cfg.ollama_override)
            s = load_session(self.sid) or s
            s.summary_md = md
            if s.status == "error":
                s.status = "done"; s.error = None
            s.save()
            self.updated.emit(s.id)
        except ApiError as e:
            self.failed.emit(s.id, str(e))


class MixThread(QThread):
    """Mix mic + system audio once into mixed.m4a for playback."""
    done = Signal(str, str)       # session id, path (or "" on failure)

    def __init__(self, s: Session):
        super().__init__()
        self.s = s

    def run(self) -> None:
        out = self.s.dir / "mixed.m4a"
        try:
            subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                            "-i", str(self.s.audio_path), "-i", str(self.s.system_path),
                            "-filter_complex", "amix=inputs=2:normalize=0",
                            "-c:a", "aac", str(out)], check=True, timeout=180)
            self.done.emit(self.s.id, str(out))
        except Exception:
            self.done.emit(self.s.id, "")


# --------------------------------------------------------------------------- dialogs

def _source_combo(monitor: bool, current: str, with_none: bool = False) -> QComboBox:
    c = QComboBox()
    if with_none:
        c.addItem("—  (nicht aufnehmen)", "")
    c.addItem("Standard", "")
    for name, desc, is_mon in sources():
        if is_mon == monitor:
            c.addItem(desc, name)
    idx = c.findData(current)
    c.setCurrentIndex(idx if idx >= 0 else 0)
    return c


class SettingsDialog(QDialog):
    def __init__(self, cfg: Config, parent=None):
        super().__init__(parent)
        self.cfg = cfg
        self.setWindowTitle("Einstellungen")
        self.setMinimumWidth(460)
        form = QFormLayout(self)

        self.server = QLineEdit(str(cfg["server_url"]))
        self.token = QLineEdit(str(cfg["token"]))
        self.token.setEchoMode(QLineEdit.Password)
        test = QPushButton("Verbindung testen")
        self.test_label = QLabel("")
        test.clicked.connect(self._test)
        row = QWidget(); rl = QHBoxLayout(row); rl.setContentsMargins(0, 0, 0, 0)
        rl.addWidget(test); rl.addWidget(self.test_label); rl.addStretch()

        self.lang = QComboBox()
        for label, tag in (("Deutsch", "de"), ("Englisch", "en"), ("Automatisch", "")):
            self.lang.addItem(label, tag)
        self.lang.setCurrentIndex(max(0, self.lang.findData(str(cfg["language"]))))

        self.mic = _source_combo(False, str(cfg["mic_source"]))
        self.sysrc = _source_combo(True, str(cfg["system_source"]) or default_monitor(),
                                   with_none=True)

        self.speakers = QSpinBox(); self.speakers.setRange(0, 8)
        self.speakers.setSpecialValueText("Automatisch")
        self.speakers.setValue(int(cfg["speaker_count"]))

        self.vocab = QPlainTextEdit(str(cfg["vocabulary"]))
        self.vocab.setPlaceholderText("z. B. Yael, Noa, Ollama, Tailscale")
        self.vocab.setFixedHeight(60)

        self.ollama = QLineEdit(str(cfg["ollama_url"]))
        self.ollama.setPlaceholderText("leer = Server nutzt sein eigenes Ollama")
        self.model = QComboBox()
        self.model.addItem("Automatisch", "")
        reload_models = QPushButton("Modelle laden")
        reload_models.clicked.connect(self._load_models)

        form.addRow("Server-URL", self.server)
        form.addRow("Token", self.token)
        form.addRow("", row)
        form.addRow("Gesprochene Sprache", self.lang)
        form.addRow("Mikrofon", self.mic)
        form.addRow("Systemton", self.sysrc)
        form.addRow("Sprecher (Standard)", self.speakers)
        form.addRow("Namen & Begriffe", self.vocab)
        form.addRow("Ollama-Server", self.ollama)
        form.addRow("Protokoll-Modell", self.model)
        form.addRow("", reload_models)

        bb = QDialogButtonBox(QDialogButtonBox.Save | QDialogButtonBox.Cancel)
        bb.accepted.connect(self._save); bb.rejected.connect(self.reject)
        form.addRow(bb)
        QTimer.singleShot(0, self._load_models)

    def _api(self) -> ScribeAPI:
        return ScribeAPI(self.server.text().strip(), self.token.text())

    def _ollama_now(self) -> str:
        raw = self.ollama.text().strip()
        import re
        return raw if re.match(r"^https?://[^/\s]+", raw) else ""

    def _test(self):
        self.test_label.setText("…")
        ok = self._api().health()
        self.test_label.setText("erreichbar" if ok else "nicht erreichbar")

    def _load_models(self):
        try:
            info = self._api().models(self._ollama_now())
        except ApiError:
            return
        want = str(self.cfg["summary_model"])
        self.model.clear()
        eff = info.get("effective") or ""
        self.model.addItem(f"Automatisch ({eff})" if eff else "Automatisch", "")
        for m in info.get("available", []):
            self.model.addItem(m, m)
        idx = self.model.findData(want)
        self.model.setCurrentIndex(idx if idx >= 0 else 0)

    def _save(self):
        c = self.cfg
        c["server_url"] = self.server.text().strip()
        c["token"] = self.token.text()
        c["language"] = self.lang.currentData()
        c["mic_source"] = self.mic.currentData()
        c["system_source"] = self.sysrc.currentData()
        c["speaker_count"] = self.speakers.value()
        c["vocabulary"] = self.vocab.toPlainText()
        c["ollama_url"] = self.ollama.text().strip()
        c["summary_model"] = self.model.currentData()
        self.accept()


class RecordDialog(QDialog):
    finished_session = Signal(str)

    def __init__(self, cfg: Config, parent=None):
        super().__init__(parent)
        self.cfg = cfg
        self.rec = Recorder()
        self.session: Session | None = None
        self.setWindowTitle("Neue Aufnahme")
        self.setMinimumWidth(420)
        v = QVBoxLayout(self)

        self.kind = QComboBox()
        self.kind.addItem("Meeting", "meeting")
        self.kind.addItem("Voice Note", "voicenote")
        self.title = QLineEdit(); self.title.setPlaceholderText("Titel (optional)")
        self.mic = _source_combo(False, str(cfg["mic_source"]))
        self.with_system = QCheckBox("Systemton mit aufnehmen"); self.with_system.setChecked(True)
        self.sysrc = _source_combo(True, str(cfg["system_source"]) or default_monitor())
        self.speakers = QSpinBox(); self.speakers.setRange(0, 8)
        self.speakers.setSpecialValueText("Automatisch")
        self.speakers.setValue(int(cfg["speaker_count"]))

        f = QFormLayout()
        f.addRow("Typ", self.kind)
        f.addRow("Titel", self.title)
        f.addRow("Mikrofon", self.mic)
        f.addRow(self.with_system)
        f.addRow("Systemton", self.sysrc)
        f.addRow("Sprecher", self.speakers)
        v.addLayout(f)

        self.status = QLabel("Bereit."); self.status.setAlignment(Qt.AlignCenter)
        v.addWidget(self.status)

        self.marker_btn = QPushButton("Stelle merken  (M)")
        self.marker_btn.setShortcut(QKeySequence("M"))
        self.marker_btn.clicked.connect(self._mark)
        self.marker_btn.setEnabled(False)
        v.addWidget(self.marker_btn)

        row = QHBoxLayout()
        self.cancel_btn = QPushButton("Abbrechen"); self.cancel_btn.clicked.connect(self._cancel)
        self.go_btn = QPushButton("Aufnehmen"); self.go_btn.clicked.connect(self._toggle)
        row.addWidget(self.cancel_btn); row.addStretch(); row.addWidget(self.go_btn)
        v.addLayout(row)

        self.kind.currentIndexChanged.connect(self._sync_meeting_rows)
        self._sync_meeting_rows()
        self.timer = QTimer(self); self.timer.timeout.connect(self._tick)

    def _sync_meeting_rows(self):
        meeting = self.kind.currentData() == "meeting"
        self.with_system.setVisible(meeting)
        self.sysrc.setVisible(meeting)

    def _mark(self):
        if self.session and self.rec.is_recording:
            self.session.markers.append(round(self.rec.elapsed, 1))
            self._tick()

    def _tick(self):
        n = len(self.session.markers) if self.session else 0
        self.status.setText(f"Aufnahme läuft · {mmss(self.rec.elapsed)}"
                            + (f" · {n} Marker" if n else ""))

    def _toggle(self):
        if self.rec.is_recording:
            self._stop_and_send()
            return
        if not have_ffmpeg():
            QMessageBox.warning(self, "ffmpeg fehlt", "Bitte 'ffmpeg' installieren.")
            return
        kind = self.kind.currentData()
        self.session = Session.new(kind, self.title.text().strip())
        self.session.speaker_count = self.speakers.value()
        self.session.save()
        use_system = kind == "meeting" and self.with_system.isChecked()
        try:
            self.rec.start(self.session.audio_path, self.mic.currentData(),
                           self.session.system_path if use_system else None,
                           self.sysrc.currentData() if use_system else "")
        except Exception as e:
            QMessageBox.critical(self, "Fehler", str(e))
            delete_session(self.session); self.session = None
            return
        self.go_btn.setText("Stopp")
        self.marker_btn.setEnabled(True)
        for w in (self.kind, self.title, self.mic, self.with_system, self.sysrc, self.speakers):
            w.setEnabled(False)
        self.timer.start(500)

    def _stop_and_send(self):
        self.timer.stop()
        dur = self.rec.stop()
        s = self.session
        s.duration = dur
        s.has_system_audio = self.rec.captured_system
        s.status = "uploading"
        s.save()
        self.finished_session.emit(s.id)
        self.accept()

    def _cancel(self):
        if self.rec.is_recording:
            self.rec.stop()
        if self.session:
            delete_session(self.session)
        self.reject()


class ImportDialog(QDialog):
    imported = Signal(str)

    def __init__(self, cfg: Config, parent=None):
        super().__init__(parent)
        self.cfg = cfg
        self.path: Path | None = None
        self.setWindowTitle("Datei importieren")
        self.setMinimumWidth(420)
        v = QVBoxLayout(self)
        f = QFormLayout()
        self.file_label = QLabel("keine Datei")
        pick = QPushButton("Wählen …"); pick.clicked.connect(self._pick)
        r = QWidget(); rl = QHBoxLayout(r); rl.setContentsMargins(0, 0, 0, 0)
        rl.addWidget(self.file_label, 1); rl.addWidget(pick)
        self.kind = QComboBox()
        self.kind.addItem("Meeting", "meeting"); self.kind.addItem("Voice Note", "voicenote")
        self.title = QLineEdit()
        self.speakers = QSpinBox(); self.speakers.setRange(0, 8)
        self.speakers.setSpecialValueText("Automatisch")
        f.addRow("Datei", r)
        f.addRow("Typ", self.kind)
        f.addRow("Titel", self.title)
        f.addRow("Sprecher", self.speakers)
        v.addLayout(f)
        bb = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel)
        bb.button(QDialogButtonBox.Ok).setText("Importieren")
        bb.accepted.connect(self._go); bb.rejected.connect(self.reject)
        v.addWidget(bb)

    def _pick(self):
        p, _ = QFileDialog.getOpenFileName(
            self, "Audio oder Video",
            filter="Audio/Video (*.m4a *.mp3 *.wav *.flac *.ogg *.opus *.mp4 *.mov *.mkv *.webm)")
        if p:
            self.path = Path(p)
            self.file_label.setText(self.path.name)
            if not self.title.text():
                self.title.setText(self.path.stem)

    def _go(self):
        if not self.path:
            return
        s = Session.new(self.kind.currentData(), self.title.text().strip() or self.path.stem)
        s.speaker_count = self.speakers.value()
        s.status = "uploading"
        s.save()
        import shutil
        s.dir.mkdir(parents=True, exist_ok=True)
        shutil.copy(self.path, s.audio_path)
        s.save()
        self.imported.emit(s.id)
        self.accept()


# --------------------------------------------------------------------------- detail

class SessionView(QWidget):
    changed = Signal(str)
    resummarize_requested = Signal(str)
    retranscribe_requested = Signal(str)

    def __init__(self, cfg: Config, parent=None):
        super().__init__(parent)
        self.cfg = cfg
        self.session: Session | None = None
        self._mix: MixThread | None = None
        v = QVBoxLayout(self)

        self.header = QLabel(); self.header.setTextFormat(Qt.RichText); self.header.setWordWrap(True)
        v.addWidget(self.header)

        pb = QHBoxLayout()
        self.play_btn = QToolButton(); self.play_btn.setText("▶")
        self.play_btn.clicked.connect(self._toggle_play)
        self.scrub = QSlider(Qt.Horizontal); self.scrub.setRange(0, 1000)
        self.scrub.sliderMoved.connect(self._scrub_moved)
        self.time_label = QLabel("0:00 / 0:00")
        pb.addWidget(self.play_btn); pb.addWidget(self.scrub, 1); pb.addWidget(self.time_label)
        v.addLayout(pb)

        self.markers_label = QLabel(""); self.markers_label.setStyleSheet("color: gray")
        v.addWidget(self.markers_label)

        self.tabs = QTabWidget()
        self.summary_view = QTextBrowser(); self.summary_view.setOpenExternalLinks(True)
        self.speaker_box = QWidget(); self.speaker_form = QFormLayout(self.speaker_box)
        self.transcript_list = QListWidget()
        self.transcript_list.setWordWrap(True)
        self.transcript_list.itemClicked.connect(self._transcript_clicked)
        tw = QWidget(); tl = QVBoxLayout(tw)
        tl.addWidget(self.speaker_box); tl.addWidget(self.transcript_list, 1)
        self.tabs.addTab(self.summary_view, "Protokoll")
        self.tabs.addTab(tw, "Transkript")
        v.addWidget(self.tabs, 1)

        self.status_label = QLabel(""); v.addWidget(self.status_label)

        self.player = QMediaPlayer(self)
        self.audio_out = QAudioOutput(self)
        self.player.setAudioOutput(self.audio_out)
        self.player.positionChanged.connect(self._pos_changed)
        self.player.durationChanged.connect(lambda _: self._pos_changed(self.player.position()))

    def show_session(self, s: Session | None):
        self.session = s
        self.player.stop(); self.player.setSource(QUrl())
        self.play_btn.setText("▶")
        if not s:
            self.header.setText("<i>Keine Aufnahme gewählt</i>")
            self.summary_view.clear(); self.transcript_list.clear()
            self._clear_speakers(); self.status_label.clear(); self.markers_label.clear()
            return

        meta = f"{'Meeting' if s.kind == 'meeting' else 'Voice Note'} · {s.display_title}"
        if s.duration:
            meta += f" · {mmss(s.duration)}"
        if s.language:
            meta += f" · {s.language.upper()}"
        self.header.setText(f"<b style='font-size:15px'>{s.display_title}</b><br>"
                            f"<span style='color:gray'>{meta}</span>")
        self.status_label.setText({
            "uploading": "Wird hochgeladen …", "processing": "Wird transkribiert …",
            "queued": "In der Warteschlange …", "running": "Wird transkribiert …",
            "transcribed": "Protokoll wird erstellt …",
            "error": f"Fehler: {s.error or ''}",
        }.get(s.status, ""))

        self.summary_view.setMarkdown(s.rendered_summary or "_(noch kein Protokoll)_")
        self._fill_transcript(s)
        self._fill_speakers(s)
        self.markers_label.setText(
            "Marker: " + "  ".join(mmss(m) for m in s.markers) if s.markers else "")

        # playback source (mix mic + system lazily, off the UI thread)
        src = None
        if s.audio_path.exists():
            if s.has_system_audio and s.system_path.exists():
                mixed = s.dir / "mixed.m4a"
                if mixed.exists():
                    src = mixed
                else:
                    src = s.audio_path
                    self._start_mix(s)
            else:
                src = s.audio_path
        if src:
            self.player.setSource(QUrl.fromLocalFile(str(src)))
        self.play_btn.setEnabled(bool(src))
        self.scrub.setEnabled(bool(src))

    def _start_mix(self, s: Session):
        if self._mix and self._mix.isRunning():
            return
        self._mix = MixThread(s)
        self._mix.done.connect(self._mix_done)
        self._mix.start()

    def _mix_done(self, sid: str, path: str):
        if path and self.session and self.session.id == sid:
            at = self.player.position()
            self.player.setSource(QUrl.fromLocalFile(path))
            self.player.setPosition(at)

    def _fill_transcript(self, s: Session):
        self.transcript_list.clear()
        if not s.segments:
            it = QListWidgetItem(s.rendered_transcript or "—")
            it.setData(Qt.UserRole, 0.0)
            self.transcript_list.addItem(it)
            return
        for speaker, segs in s.speaker_groups:
            who = s.speaker_label(speaker)
            text = " ".join(seg.text for seg in segs).strip()
            it = QListWidgetItem(f"{who} · {mmss(segs[0].start_time)}\n{text}")
            it.setData(Qt.UserRole, segs[0].start_time)
            self.transcript_list.addItem(it)

    def _clear_speakers(self):
        while self.speaker_form.rowCount():
            self.speaker_form.removeRow(0)

    def _fill_speakers(self, s: Session):
        self._clear_speakers()
        if not s.speakers:
            return
        for tag in s.speakers:
            edit = QLineEdit(s.speaker_names.get(tag, ""))
            edit.setPlaceholderText(tag)
            edit.editingFinished.connect(
                lambda t=tag, e=edit: self._rename_speaker(t, e.text()))
            self.speaker_form.addRow(tag, edit)
        if s.status in ("done", "transcribed", "error"):
            resum = QPushButton("Protokoll neu erstellen")
            resum.clicked.connect(lambda: self.resummarize_requested.emit(s.id))
            self.speaker_form.addRow("", resum)
            rerow = QWidget(); rl = QHBoxLayout(rerow); rl.setContentsMargins(0, 0, 0, 0)
            rl.addWidget(QLabel("Falsche Sprecherzahl?"))
            box = QSpinBox(); box.setRange(0, 8); box.setSpecialValueText("Automatisch")
            box.setValue(s.speaker_count)
            btn = QPushButton("Neu transkribieren")
            btn.clicked.connect(lambda: self._retranscribe(s.id, box.value()))
            rl.addWidget(box); rl.addWidget(btn); rl.addStretch()
            self.speaker_form.addRow("", rerow)

    def _retranscribe(self, sid: str, count: int):
        cur = load_session(sid)
        if cur:
            cur.speaker_count = count
            cur.server_job_id = None
            cur.save()
        self.retranscribe_requested.emit(sid)

    def _rename_speaker(self, tag: str, name: str):
        if not self.session:
            return
        self.session.speaker_names[tag] = name.strip()
        self.session.save()
        self.summary_view.setMarkdown(self.session.rendered_summary)
        self._fill_transcript(self.session)
        self.changed.emit(self.session.id)

    def _toggle_play(self):
        if self.player.playbackState() == QMediaPlayer.PlayingState:
            self.player.pause(); self.play_btn.setText("▶")
        else:
            self.player.play(); self.play_btn.setText("⏸")

    def _scrub_moved(self, v: int):
        if self.player.duration():
            self.player.setPosition(int(self.player.duration() * v / 1000))

    def _pos_changed(self, pos: int):
        dur = self.player.duration() or 1
        if not self.scrub.isSliderDown():
            self.scrub.setValue(int(1000 * pos / dur))
        self.time_label.setText(f"{mmss(pos/1000)} / {mmss(dur/1000)}")
        if self.session and self.session.segments:
            t = pos / 1000
            for i, (_, segs) in enumerate(self.session.speaker_groups):
                last = segs[-1]
                if segs[0].start_time <= t < (last.end or last.start_time + 4):
                    self.transcript_list.setCurrentRow(i)
                    break

    def _transcript_clicked(self, it: QListWidgetItem):
        if self.player.source().isValid():
            self.player.setPosition(int(float(it.data(Qt.UserRole) or 0) * 1000))
            self.player.play(); self.play_btn.setText("⏸")


# --------------------------------------------------------------------------- window

class MainWindow(QMainWindow):
    def __init__(self, cfg: Config):
        super().__init__()
        self.cfg = cfg
        self._threads: dict[str, QThread] = {}
        self.setWindowTitle("Afterword")
        self.resize(1000, 640)

        tb = self.addToolBar("main"); tb.setMovable(False)
        a_rec = QAction("Aufnehmen", self); a_rec.triggered.connect(self.record)
        a_imp = QAction("Importieren", self); a_imp.triggered.connect(self.do_import)
        a_set = QAction("Einstellungen", self); a_set.triggered.connect(self.settings)
        a_set.setShortcut(QKeySequence("Ctrl+,"))
        tb.addAction(a_rec); tb.addAction(a_imp)
        spacer = QWidget(); spacer.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Preferred)
        tb.addWidget(spacer); tb.addAction(a_set)

        split = QSplitter()
        self.list = QListWidget(); self.list.setMaximumWidth(320)
        self.list.currentItemChanged.connect(self._selected)
        self.list.setContextMenuPolicy(Qt.CustomContextMenu)
        self.list.customContextMenuRequested.connect(self._list_menu)
        self.detail = SessionView(cfg)
        self.detail.changed.connect(lambda _: self.refresh_list())
        self.detail.resummarize_requested.connect(self.resummarize)
        self.detail.retranscribe_requested.connect(self.start_job)
        split.addWidget(self.list); split.addWidget(self.detail)
        split.setStretchFactor(1, 1)
        self.setCentralWidget(split)

        menu = self.menuBar().addMenu("Aufnahme")
        menu.addAction("Als Markdown exportieren …", lambda: self._export("md"))
        menu.addAction("Als Untertitel (.srt) exportieren …", lambda: self._export("srt"))

        self.refresh_list()
        self.timer = QTimer(self); self.timer.timeout.connect(self._poll_busy)
        self.timer.start(POLL_MS)
        QTimer.singleShot(300, self._poll_busy)

    # ---- list

    def refresh_list(self):
        cur = self._current_id()
        self.list.blockSignals(True)
        self.list.clear()
        for s in all_sessions():
            dot = {"done": "●", "error": "▲"}.get(s.status, "…")
            it = QListWidgetItem(f"{dot}  {s.display_title}")
            it.setData(Qt.UserRole, s.id)
            self.list.addItem(it)
            if s.id == cur:
                self.list.setCurrentItem(it)
        self.list.blockSignals(False)
        if not self._current_id() and self.list.count():
            self.list.setCurrentRow(0)

    def _current_id(self) -> str | None:
        it = self.list.currentItem()
        return it.data(Qt.UserRole) if it else None

    def _selected(self, *_):
        sid = self._current_id()
        self.detail.show_session(load_session(sid) if sid else None)

    def _list_menu(self, pos):
        it = self.list.itemAt(pos)
        if not it:
            return
        s = load_session(it.data(Qt.UserRole))
        if not s:
            return
        m = QMenu(self)
        m.addAction("Umbenennen …", lambda: self._rename(s))
        if s.status in ("done", "error"):
            m.addAction("Erneut transkribieren", lambda: self._retry_full(s.id))
        m.addAction("Löschen", lambda: self._delete(s))
        m.exec(self.list.mapToGlobal(pos))

    def _rename(self, s: Session):
        name, ok = QInputDialog.getText(self, "Umbenennen", "Titel:", text=s.title)
        if ok:
            s.title = name.strip(); s.save(); self.refresh_list()

    def _delete(self, s: Session):
        if QMessageBox.question(self, "Löschen",
                                f"„{s.display_title}“ löschen?") == QMessageBox.Yes:
            delete_session(s); self.refresh_list()

    def _retry_full(self, sid: str):
        s = load_session(sid)
        if s:
            s.server_job_id = None; s.save()
        self.start_job(sid)

    # ---- actions

    def record(self):
        d = RecordDialog(self.cfg, self)
        d.finished_session.connect(self._after_new)
        d.exec()

    def do_import(self):
        d = ImportDialog(self.cfg, self)
        d.imported.connect(self._after_new)
        d.exec()

    def _after_new(self, sid: str):
        self.refresh_list()
        self._select(sid)
        self.start_job(sid)

    def _select(self, sid: str):
        for i in range(self.list.count()):
            if self.list.item(i).data(Qt.UserRole) == sid:
                self.list.setCurrentRow(i); return

    def settings(self):
        if SettingsDialog(self.cfg, self).exec():
            self.refresh_list()

    def start_job(self, sid: str):
        if sid in self._threads and self._threads[sid].isRunning():
            return
        s = load_session(sid)
        if s and s.status == "error":
            s.status = "uploading"; s.error = None; s.save()
        t = TranscribeThread(self.cfg, sid)
        t.updated.connect(self._job_updated)
        t.failed.connect(self._job_failed)
        t.finished.connect(lambda: self._threads.pop(sid, None))
        self._threads[sid] = t
        t.start()
        self.refresh_list()

    def resummarize(self, sid: str):
        key = "resum:" + sid
        if key in self._threads and self._threads[key].isRunning():
            return
        t = ResummarizeThread(self.cfg, sid)
        t.updated.connect(self._job_updated)
        t.failed.connect(self._job_failed)
        t.finished.connect(lambda: self._threads.pop(key, None))
        self._threads[key] = t
        t.start()

    def _job_updated(self, sid: str):
        self.refresh_list()
        if self._current_id() == sid:
            self._selected()

    def _job_failed(self, sid: str, msg: str):
        self.refresh_list()
        if self._current_id() == sid:
            self._selected()
        self.statusBar().showMessage(msg, 8000)

    def _poll_busy(self):
        for s in all_sessions():
            if s.status in STATUS_BUSY and s.id not in self._threads:
                self.start_job(s.id)

    # ---- export

    def _export(self, fmt: str):
        s = load_session(self._current_id() or "")
        if not s:
            return
        name = s.display_title.replace("/", "-")
        if fmt == "md":
            path, _ = QFileDialog.getSaveFileName(self, "Speichern", f"{name}.md")
            text = self._md(s)
        else:
            path, _ = QFileDialog.getSaveFileName(self, "Speichern", f"{name}.srt")
            text = self._srt(s)
        if path:
            Path(path).write_text(text, encoding="utf-8")

    def _md(self, s: Session) -> str:
        out = f"# {s.display_title}\n\n"
        out += f"{'Meeting' if s.kind == 'meeting' else 'Voice Note'} · {s.display_title}"
        if s.duration:
            out += f" · {mmss(s.duration)}"
        out += "\n\n" + (s.rendered_summary or "_(kein Protokoll)_") + "\n\n---\n\n"
        out += f"# {s.display_title} — Transkript\n\n"
        last = None
        for seg in s.segments:
            who = s.speaker_label(seg.speaker)
            if who != last:
                out += f"\n**{who}**\n\n"; last = who
            out += f"`{mmss(seg.start_time)}`  {seg.text}\n"
        return out

    def _srt(self, s: Session) -> str:
        def ts(x):
            h, m, sec = int(x) // 3600, (int(x) % 3600) // 60, int(x) % 60
            return f"{h:02d}:{m:02d}:{sec:02d},{int((x - int(x)) * 1000):03d}"
        out = f"1\n{ts(0)} --> {ts(2.5)}\n{s.display_title}\n\n"
        for i, seg in enumerate(s.segments):
            start = seg.start or 0
            out += f"{i + 2}\n{ts(start)} --> {ts(seg.end or start + 3)}\n"
            out += f"{s.speaker_label(seg.speaker)}: {seg.text}\n\n"
        return out

    def closeEvent(self, e):
        for t in list(self._threads.values()):
            t.requestInterruption()
        for t in list(self._threads.values()):
            t.wait(2000)
        e.accept()


def main():
    app = QApplication(sys.argv)
    app.setApplicationName("Afterword")
    w = MainWindow(Config())
    w.show()
    sys.exit(app.exec())

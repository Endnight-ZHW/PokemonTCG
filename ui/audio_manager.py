"""Simple audio manager with procedurally generated sound effects."""
import math
import pygame
from config import SFX_ENABLED, SFX_VOLUME

_numpy_available = False
try:
    import numpy as np
    _numpy_available = True
except ImportError:
    pass


class AudioManager:
    """Manages sound effects generated procedurally."""

    _instance = None

    def __init__(self):
        self.enabled = SFX_ENABLED
        self.volume = SFX_VOLUME
        self._sounds: dict[str, pygame.mixer.Sound] = {}
        self._initialized = False

    @classmethod
    def get(cls) -> "AudioManager":
        if cls._instance is None:
            cls._instance = cls()
        return cls._instance

    def init(self):
        """Initialize the mixer and generate sounds."""
        if self._initialized:
            return
        self._initialized = True
        try:
            pygame.mixer.init(frequency=22050, size=-16, channels=2, buffer=512)
            if _numpy_available:
                self._generate_sounds()
        except pygame.error:
            self.enabled = False

    def _generate_sounds(self):
        """Generate all sound effects procedurally."""
        sample_rate = 22050

        self._sounds["click"] = self._make_sound(
            self._mix(
                self._gen_tone(sample_rate, 800, 0.03, "square"),
                self._gen_tone(sample_rate, 1200, 0.015, "square", delay=0.01),
            ),
            sample_rate
        )
        self._sounds["card_place"] = self._make_sound(
            self._mix(
                self._gen_tone(sample_rate, 200, 0.06, "sine"),
                self._gen_noise(0.03, 0.3, sample_rate),
            ),
            sample_rate
        )
        self._sounds["card_draw"] = self._make_sound(
            self._gen_sweep(sample_rate, 400, 900, 0.05),
            sample_rate
        )
        self._sounds["attack_hit"] = self._make_sound(
            self._mix(
                self._gen_noise(0.06, 0.7, sample_rate),
                self._gen_tone(sample_rate, 150, 0.08, "sine"),
            ),
            sample_rate
        )
        self._sounds["energy_attach"] = self._make_sound(
            self._mix(
                self._gen_tone(sample_rate, 600, 0.05, "sine"),
                self._gen_tone(sample_rate, 900, 0.03, "sine", delay=0.03),
            ),
            sample_rate
        )
        self._sounds["evolution"] = self._make_sound(
            self._mix(
                self._gen_sweep(sample_rate, 300, 1200, 0.15),
                self._gen_tone(sample_rate, 1200, 0.05, "sine", delay=0.12),
                self._gen_tone(sample_rate, 1600, 0.08, "sine", delay=0.15),
            ),
            sample_rate
        )
        self._sounds["pokemon_ko"] = self._make_sound(
            self._mix(
                self._gen_sweep(sample_rate, 600, 80, 0.2),
                self._gen_noise(0.1, 0.3, sample_rate),
            ),
            sample_rate
        )
        self._sounds["turn_change"] = self._make_sound(
            self._mix(
                self._gen_tone(sample_rate, 500, 0.06, "sine"),
                self._gen_tone(sample_rate, 700, 0.06, "sine", delay=0.06),
            ),
            sample_rate
        )
        self._sounds["victory"] = self._make_sound(
            self._mix(
                self._gen_tone(sample_rate, 500, 0.1, "sine"),
                self._gen_tone(sample_rate, 700, 0.1, "sine", delay=0.1),
                self._gen_tone(sample_rate, 900, 0.15, "sine", delay=0.2),
                self._gen_tone(sample_rate, 1100, 0.2, "sine", delay=0.3),
            ),
            sample_rate
        )

    def _mix(self, *waves):
        """Pad generated waveforms to the same length, then mix them."""
        if not waves:
            return np.zeros(1)
        max_len = max(len(wave) for wave in waves)
        mixed = np.zeros(max_len)
        for wave in waves:
            mixed[:len(wave)] += wave
        return np.clip(mixed, -1.0, 1.0)

    def _gen_tone(self, sample_rate: int, freq: float, duration: float,
                  shape: str = "sine", delay: float = 0.0):
        """Generate a tone waveform."""
        samples = int(sample_rate * (delay + duration))
        t = np.arange(samples) / sample_rate
        wave = np.zeros(samples)
        start = int(delay * sample_rate)
        end = start + int(duration * sample_rate)
        tone_t = t[:end - start]
        if shape == "square":
            wave[start:end] = np.sign(np.sin(2 * math.pi * freq * tone_t))
        else:
            wave[start:end] = np.sin(2 * math.pi * freq * tone_t)
        # Apply envelope
        env = np.linspace(0, 1, min(100, end - start))
        env_end = np.linspace(1, 0, min(200, end - start))
        wave[start:start + len(env)] *= env
        wave[end - len(env_end):end] *= env_end
        return wave

    def _gen_sweep(self, sample_rate: int, freq_start: float, freq_end: float,
                   duration: float):
        """Generate a frequency sweep."""
        samples = int(sample_rate * duration)
        t = np.arange(samples) / sample_rate
        freq = np.linspace(freq_start, freq_end, samples)
        wave = np.sin(2 * math.pi * freq * t)
        env = np.linspace(1, 0, samples)
        wave *= env
        return wave

    def _gen_noise(self, duration: float, amplitude: float = 0.5,
                   sample_rate: int = 22050):
        """Generate white noise."""
        samples = int(sample_rate * duration)
        wave = np.random.uniform(-amplitude, amplitude, samples)
        env = np.linspace(1, 0, samples)
        wave *= env
        return wave

    def _make_sound(self, wave, sample_rate: int) -> pygame.mixer.Sound:
        """Convert numpy array to pygame Sound."""
        # Normalize
        max_val = np.max(np.abs(wave))
        if max_val > 0:
            wave = wave / max_val * 0.8
        # Convert to 16-bit
        wave_int = (wave * 32767).astype(np.int16)
        # Make stereo by duplicating
        stereo = np.column_stack((wave_int, wave_int))
        return pygame.sndarray.make_sound(stereo)

    def play(self, name: str):
        """Play a named sound effect."""
        if not self.enabled or not self._initialized:
            return
        sound = self._sounds.get(name)
        if sound:
            sound.set_volume(self.volume)
            sound.play()

    def set_volume(self, vol: float):
        self.volume = max(0.0, min(1.0, vol))

    def toggle_mute(self):
        self.enabled = not self.enabled

    def cleanup(self):
        pygame.mixer.quit()


# ── Convenience functions ──────────────────────────────────────

def get_audio() -> AudioManager:
    return AudioManager.get()

class_name UISound
extends RefCounted


static func make_tone(
	frequency: float = 660.0,
	duration: float = 0.07,
	volume: float = 0.16,
) -> AudioStreamWAV:
	var sample_rate := 22050
	var sample_count := int(sample_rate * duration)
	var bytes := PackedByteArray()
	bytes.resize(sample_count * 2)
	for index in range(sample_count):
		var progress := float(index) / float(max(1, sample_count - 1))
		var envelope := 1.0 - progress
		var wave := sin(TAU * frequency * float(index) / float(sample_rate))
		var sample := int(clamp(wave * envelope * volume, -1.0, 1.0) * 32767.0)
		bytes.encode_s16(index * 2, sample)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = sample_rate
	stream.stereo = false
	stream.data = bytes
	return stream

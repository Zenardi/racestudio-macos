//! GPS decoding (issue 1.4): the container's `GPS` NAV-SOL messages decoded into
//! a typed [`GpsData`] — latitude/longitude, altitude, speed, accuracy, and
//! satellite count — clean-room, validated against libxrk's synthesized GPS
//! channels as the golden oracle.
//!
//! AiM loggers store GPS as a stream of fixed 56-byte u-blox **NAV-SOL** header
//! messages (token `GPS`/`GPS1`), separate from the analog/CAN channels. Each
//! record carries ECEF position (cm) and velocity (cm/s) plus accuracy and
//! satellite fields. [`decode_gps`]:
//!
//! - converts ECEF → geodetic latitude/longitude/altitude with the closed-form
//!   **Vermeille 2003** algorithm (matching libxrk to 1e-8),
//! - derives speed as `‖ecef velocity‖ / 100` in m/s (stored as-is; a `speed_kmh`
//!   accessor is offered but the m/s value is the source of truth),
//! - scales position/velocity accuracy and pDOP, and reads the fix type and
//!   satellite count, and
//! - reconstructs timecodes mangled by an old-firmware 16-bit-overflow bug.
//!
//! It also exposes libxrk's **computed** GPS channels — inline/lateral
//! acceleration and yaw rate, differentiated from speed and heading — tagged
//! [`GpsChannelKind::Computed`] so callers can prefer raw over derived
//! deterministically. Lap/timing (1.5) and the unified `Session` (1.6) are out of
//! scope.

use std::f64::consts::PI;

use crate::container::{le_i32, le_u16, le_u32, read_header, tokstr, Container, MAGIC};
use crate::error::DecodeError;

/// Bytes per u-blox NAV-SOL record.
const GPS_RECORD_LEN: usize = 56;

/// Whether a GPS channel is a direct NAV-SOL measurement or a derived quantity.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GpsChannelKind {
    /// Read straight from the NAV-SOL record (position, speed, accuracy, …).
    Raw,
    /// Computed by differentiating raw channels (acceleration, yaw rate).
    Computed,
}

/// One decoded GPS channel: a named, unit-tagged series with a
/// [`GpsChannelKind`].
#[derive(Debug, Clone)]
pub struct GpsChannel {
    name: String,
    kind: GpsChannelKind,
    unit: String,
    interpolate: bool,
    samples: Vec<(f64, f64)>,
}

impl GpsChannel {
    /// Channel name (e.g. `GPS Latitude`, `GPS_InlineAcc`).
    #[must_use]
    pub fn name(&self) -> &str {
        &self.name
    }

    /// Whether the channel is [`Raw`](GpsChannelKind::Raw) or
    /// [`Computed`](GpsChannelKind::Computed).
    #[must_use]
    pub fn kind(&self) -> GpsChannelKind {
        self.kind
    }

    /// Physical unit (e.g. `deg`, `m/s`, `g`); empty when dimensionless.
    #[must_use]
    pub fn unit(&self) -> &str {
        &self.unit
    }

    /// Whether the channel is linearly interpolated (`true`, matching libxrk for
    /// position/speed/accel/accuracy) or step-held (`false`, for the discrete
    /// satellite count, fix type, and pDOP). Governs resampling between fixes.
    #[must_use]
    pub fn interpolate(&self) -> bool {
        self.interpolate
    }

    /// The channel's samples as `(timecode_ms, value)` pairs.
    #[must_use]
    pub fn samples(&self) -> &[(f64, f64)] {
        &self.samples
    }
}

/// A single GPS fix: the raw NAV-SOL measurements for one record.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct GpsFix {
    /// Logger timecode in milliseconds (overflow-corrected).
    pub timecode_ms: f64,
    /// Latitude in degrees (WGS84).
    pub latitude: f64,
    /// Longitude in degrees (WGS84).
    pub longitude: f64,
    /// Altitude in metres (WGS84 ellipsoidal height).
    pub altitude_m: f64,
    /// Ground speed in metres per second, as stored (no unit conversion).
    pub speed_ms: f64,
    /// 3D position accuracy in metres.
    pub position_accuracy_m: f64,
    /// Speed accuracy in metres per second.
    pub velocity_accuracy_ms: f64,
    /// Position dilution of precision.
    pub pdop: f64,
    /// Number of satellites used in the fix.
    pub satellites: u8,
    /// Fix type (0 = none, 2 = 2D, 3 = 3D).
    pub fix: u8,
}

impl GpsFix {
    /// Ground speed in km/h. The stored value is [`speed_ms`](Self::speed_ms);
    /// this is a convenience conversion (`× 3.6`).
    #[must_use]
    pub fn speed_kmh(&self) -> f64 {
        self.speed_ms * 3.6
    }
}

/// Decoded GPS for a session: the per-sample [`GpsFix`]es plus the named GPS
/// channels (raw + computed).
#[derive(Debug, Clone)]
pub struct GpsData {
    fixes: Vec<GpsFix>,
    channels: Vec<GpsChannel>,
}

impl GpsData {
    /// The per-sample GPS fixes, in chronological order.
    #[must_use]
    pub fn fixes(&self) -> &[GpsFix] {
        &self.fixes
    }

    /// All GPS channels (raw NAV-SOL + computed), each tagged with its
    /// [`GpsChannelKind`].
    #[must_use]
    pub fn channels(&self) -> &[GpsChannel] {
        &self.channels
    }

    /// The GPS channel with the given name, if present.
    #[must_use]
    pub fn channel(&self, name: &str) -> Option<&GpsChannel> {
        self.channels.iter().find(|c| c.name == name)
    }

    /// Number of GPS fixes.
    #[must_use]
    pub fn len(&self) -> usize {
        self.fixes.len()
    }

    /// Whether there are no GPS fixes.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.fixes.is_empty()
    }
}

/// Decode the GPS stream of an opened container.
///
/// Returns `Ok(None)` when the container has no GPS messages, or `Ok(Some(_))`
/// with the decoded [`GpsData`].
///
/// # Errors
/// [`DecodeError::TruncatedGps`] if the GPS bytes are not a whole number of
/// 56-byte records. Malformed input never panics.
pub fn decode_gps(container: &Container) -> Result<Option<GpsData>, DecodeError> {
    let raw = gather_gps_bytes(container.raw());
    if raw.is_empty() {
        return Ok(None);
    }
    if raw.len() % GPS_RECORD_LEN != 0 {
        return Err(DecodeError::TruncatedGps);
    }
    Ok(Some(build_gps(&raw)))
}

/// Concatenate the payloads of every `GPS`/`GPS1` message in the stream. Data
/// messages are size-skipped (using the `CHS`/`GRP` sizes) so the walk reaches
/// every GPS record throughout the file, not just those before the first sample.
fn gather_gps_bytes(bytes: &[u8]) -> Vec<u8> {
    let mut gatherer = Gatherer::default();
    gatherer.walk(bytes, true);
    gatherer.gps
}

#[derive(Default)]
struct Gatherer {
    channel_sizes: std::collections::HashMap<u16, usize>,
    group_sizes: std::collections::HashMap<u16, usize>,
    gps: Vec<u8>,
}

impl Gatherer {
    fn walk(&mut self, bytes: &[u8], top: bool) {
        let mut off = 0;
        while off + 2 <= bytes.len() {
            if bytes[off..off + 2] == MAGIC {
                let Some(header) = read_header(bytes, off) else {
                    break;
                };
                self.register(header.token, header.payload);
                off = header.next;
            } else if top && bytes[off] == b'(' {
                match self.skip_data(bytes, off) {
                    Some(next) if next > off => off = next,
                    _ => break,
                }
            } else {
                break;
            }
        }
    }

    fn register(&mut self, token: u32, payload: &[u8]) {
        match tokstr(token).as_str() {
            "CNF" | "ENF" => self.walk(payload, false),
            "CHS" => {
                if payload.len() >= 73 {
                    let index = u16::from_le_bytes([payload[0], payload[1]]);
                    self.channel_sizes.insert(index, payload[72] as usize);
                }
            }
            "GRP" => self.register_group(payload),
            "GPS" | "GPS1" => self.gps.extend_from_slice(payload),
            _ => {}
        }
    }

    fn register_group(&mut self, payload: &[u8]) {
        let (Some(gidx), Some(count)) = (le_u16(payload, 0), le_u16(payload, 2)) else {
            return;
        };
        let mut total = 0;
        for pair in payload
            .get(4..)
            .unwrap_or_default()
            .chunks_exact(2)
            .take(count as usize)
        {
            let channel = u16::from_le_bytes([pair[0], pair[1]]);
            total += self.channel_sizes.get(&channel).copied().unwrap_or(0);
        }
        self.group_sizes.insert(gidx, total);
    }

    /// Return the offset just past the data message at `off`, or `None` if it
    /// cannot be sized — which stops the walk (never panics).
    fn skip_data(&self, bytes: &[u8], off: usize) -> Option<usize> {
        match *bytes.get(off + 1)? {
            b'S' => Some(off + 9 + self.channel_sizes.get(&le_u16(bytes, off + 6)?).copied()?),
            b'M' => {
                let size = self.channel_sizes.get(&le_u16(bytes, off + 6)?).copied()?;
                Some(off + 11 + size * le_u16(bytes, off + 8)? as usize)
            }
            b'G' => Some(off + 9 + self.group_sizes.get(&le_u16(bytes, off + 6)?).copied()?),
            b'c' => match (*bytes.get(off + 2)?, *bytes.get(off + 6)?) {
                (0x00, 0x06) => Some(
                    off + 12
                        + self
                            .channel_sizes
                            .get(&(le_u16(bytes, off + 3)? >> 3))
                            .copied()?,
                ),
                (0x00, 0x08) => Some(off + 16),
                (0x01, 0x02) => Some(off + 10),
                _ => None,
            },
            _ => None,
        }
    }
}

/// Decode concatenated 56-byte NAV-SOL records into [`GpsData`].
fn build_gps(raw: &[u8]) -> GpsData {
    let records: Vec<&[u8]> = raw.chunks_exact(GPS_RECORD_LEN).collect();
    let n = records.len();

    let timecodes = correct_timecodes(&records);
    let mut fixes = Vec::with_capacity(n);
    let (mut lat, mut lon, mut alt) = (vec![0.0; n], vec![0.0; n], vec![0.0; n]);
    let (mut speed, mut pos_acc, mut vel_acc) = (vec![0.0; n], vec![0.0; n], vec![0.0; n]);
    let (mut pdop, mut sats, mut fix) = (vec![0.0; n], vec![0.0; n], vec![0.0; n]);
    let mut heading = vec![0.0; n];

    for (i, rec) in records.iter().enumerate() {
        let ex = f64::from(le_i32(rec, 16).unwrap_or(0)) / 100.0;
        let ey = f64::from(le_i32(rec, 20).unwrap_or(0)) / 100.0;
        let ez = f64::from(le_i32(rec, 24).unwrap_or(0)) / 100.0;
        let vx = f64::from(le_i32(rec, 32).unwrap_or(0));
        let vy = f64::from(le_i32(rec, 36).unwrap_or(0));
        let vz = f64::from(le_i32(rec, 40).unwrap_or(0));
        let (la, lo, al) = ecef_to_lla(ex, ey, ez);
        lat[i] = la;
        lon[i] = lo;
        alt[i] = al;
        speed[i] = (vx * vx + vy * vy + vz * vz).sqrt() / 100.0;
        pos_acc[i] = f64::from(le_u32(rec, 28).unwrap_or(0)) / 100.0;
        vel_acc[i] = f64::from(le_u32(rec, 44).unwrap_or(0)) / 100.0;
        pdop[i] = f64::from(le_u16(rec, 48).unwrap_or(0)) / 100.0;
        let numsv = rec[51];
        let fix_type = rec[14];
        sats[i] = f64::from(numsv);
        fix[i] = f64::from(fix_type);
        heading[i] = enu_heading_deg(vx, vy, vz, la, lo);
        fixes.push(GpsFix {
            timecode_ms: timecodes[i],
            latitude: la,
            longitude: lo,
            altitude_m: al,
            speed_ms: speed[i],
            position_accuracy_m: pos_acc[i],
            velocity_accuracy_ms: vel_acc[i],
            pdop: pdop[i],
            satellites: numsv,
            fix: fix_type,
        });
    }

    let (inline, lateral, yaw) = derived_channels(&timecodes, &speed, &heading);

    let mk = |name: &str, kind, unit: &str, interpolate: bool, values: &[f64]| GpsChannel {
        name: name.to_string(),
        kind,
        unit: unit.to_string(),
        interpolate,
        samples: timecodes
            .iter()
            .zip(values)
            .map(|(&t, &v)| (t, v))
            .collect(),
    };
    use GpsChannelKind::{Computed, Raw};
    // libxrk interpolates position/speed/accel/accuracy; the discrete satellite
    // count, fix type, and pDOP are step-held.
    let channels = vec![
        mk("GPS Latitude", Raw, "deg", true, &lat),
        mk("GPS Longitude", Raw, "deg", true, &lon),
        mk("GPS Altitude", Raw, "m", true, &alt),
        mk("GPS Speed", Raw, "m/s", true, &speed),
        mk("GPS_Satellites", Raw, "", false, &sats),
        mk("GPS_Fix", Raw, "", false, &fix),
        mk("GPS_pDOP", Raw, "", false, &pdop),
        mk("GPS_Position_Accuracy", Raw, "m", true, &pos_acc),
        mk("GPS_Velocity_Accuracy", Raw, "m/s", true, &vel_acc),
        mk("GPS_InlineAcc", Computed, "g", true, &inline),
        mk("GPS_LateralAcc", Computed, "g", true, &lateral),
        mk("GPS_Yaw_Rate", Computed, "deg/s", true, &yaw),
    ];

    GpsData { fixes, channels }
}

/// Reconstruct timecodes mangled by old firmware that periodically corrupts the
/// upper 16 bits: mask to the low 16, re-add the first record's high bits, then
/// add 65536 each time the masked value wraps. A no-op on well-formed streams.
fn correct_timecodes(records: &[&[u8]]) -> Vec<f64> {
    let raw: Vec<i64> = records
        .iter()
        .map(|r| i64::from(le_i32(r, 0).unwrap_or(0)))
        .collect();
    let monotonic = raw.windows(2).all(|w| w[1] >= w[0]);
    if monotonic {
        return raw.into_iter().map(|t| t as f64).collect();
    }
    let base_hi = raw[0] - (raw[0] & 0xFFFF);
    let mut out = Vec::with_capacity(raw.len());
    let mut cum = 0i64;
    let mut prev_masked = None;
    for value in raw {
        let masked = (value & 0xFFFF) + base_hi;
        if let Some(prev) = prev_masked {
            if masked < prev {
                cum += 1;
            }
        }
        prev_masked = Some(masked);
        out.push((masked + 65536 * cum) as f64);
    }
    out
}

/// Compute inline acceleration (g), lateral acceleration (g), and yaw rate
/// (deg/s) by differentiating speed and heading over the timecodes — mirroring
/// libxrk. The first sample of each is 0.
fn derived_channels(
    timecodes: &[f64],
    speed: &[f64],
    heading: &[f64],
) -> (Vec<f64>, Vec<f64>, Vec<f64>) {
    let n = timecodes.len();
    let mut inline = vec![0.0; n];
    let mut yaw = vec![0.0; n];
    let mut lateral = vec![0.0; n];
    for i in 1..n {
        let dt = (timecodes[i] - timecodes[i - 1]) / 1000.0;
        let dt = if dt > 0.0 { dt } else { f64::INFINITY };
        inline[i] = (speed[i] - speed[i - 1]) / dt / 9.81;
        let mut dh = heading[i] - heading[i - 1];
        if dh > 180.0 {
            dh -= 360.0;
        } else if dh < -180.0 {
            dh += 360.0;
        }
        yaw[i] = dh / dt;
    }
    for i in 0..n {
        lateral[i] = speed[i] * yaw[i] * (PI / 180.0) / 9.81;
    }
    (inline, lateral, yaw)
}

/// Heading (degrees, clockwise from north) from ECEF velocity, via the ENU
/// (East-North-Up) transform at the given latitude/longitude (degrees).
fn enu_heading_deg(vx: f64, vy: f64, vz: f64, lat_deg: f64, lon_deg: f64) -> f64 {
    let (lat, lon) = (lat_deg * PI / 180.0, lon_deg * PI / 180.0);
    let (sin_lat, cos_lat) = (lat.sin(), lat.cos());
    let (sin_lon, cos_lon) = (lon.sin(), lon.cos());
    let v_east = -sin_lon * vx + cos_lon * vy;
    let v_north = -sin_lat * cos_lon * vx - sin_lat * sin_lon * vy + cos_lat * vz;
    v_east.atan2(v_north) * (180.0 / PI)
}

/// WGS84 ECEF (metres) → geodetic (latitude °, longitude °, altitude m) using
/// Vermeille's 2003 closed-form solution — the exact algorithm libxrk uses, so
/// latitude/longitude match to 1e-8.
fn ecef_to_lla(x: f64, y: f64, z: f64) -> (f64, f64, f64) {
    let a = 6_378_137.0_f64;
    let e = 8.181_919_084_261_345e-2_f64;
    let e2 = e * e;
    let e4 = e2 * e2;

    let p = (x * x + y * y) * (1.0 / (a * a));
    let q = ((1.0 - e2) / (a * a)) * z * z;
    let r = (p + q - e4) * (1.0 / 6.0);
    let s = (e4 / 4.0) * p * q / (r * r * r);
    let t = (1.0 + s + (s * (2.0 + s)).sqrt()).cbrt();
    let u = r * (1.0 + t + 1.0 / t);
    let v = (u * u + e4 * q).sqrt();
    let u = u + v;
    let w = (e2 / 2.0) * (u - q) / v;
    let k = (u + w * w).sqrt() - w;
    let d = k * (x * x + y * y).sqrt() / (k + e2);
    let rt = (d * d + z * z).sqrt();
    let lat = (180.0 / PI) * 2.0 * z.atan2(d + rt);
    let lon = (180.0 / PI) * y.atan2(x);
    let alt = (k + e2 - 1.0) / k * rt;
    (lat, lon, alt)
}

#[cfg(test)]
mod tests {
    use super::*;

    const MAGIC_BYTES: [u8; 2] = MAGIC;

    fn frame(token: &str, payload: &[u8]) -> Vec<u8> {
        let mut tb = token.as_bytes().to_vec();
        while tb.len() < 4 {
            tb.push(0);
        }
        let tok = u32::from_le_bytes([tb[0], tb[1], tb[2], tb[3]]);
        let mut out = Vec::new();
        out.extend_from_slice(&MAGIC_BYTES);
        out.extend_from_slice(&tok.to_le_bytes());
        out.extend_from_slice(&(payload.len() as i32).to_le_bytes());
        out.push(0);
        out.push(b'>');
        out.extend_from_slice(payload);
        out.push(b'<');
        out.extend_from_slice(&tok.to_le_bytes());
        let checksum = (payload.iter().map(|&b| u32::from(b)).sum::<u32>() & 0xFFFF) as u16;
        out.extend_from_slice(&checksum.to_le_bytes());
        out.push(b'>');
        out
    }

    /// WGS84 geodetic → ECEF (metres), for round-trip tests.
    fn lla_to_ecef(lat_deg: f64, lon_deg: f64, h: f64) -> (f64, f64, f64) {
        let a = 6_378_137.0_f64;
        let e2 = 8.181_919_084_261_345e-2_f64.powi(2);
        let (lat, lon) = (lat_deg * PI / 180.0, lon_deg * PI / 180.0);
        let n = a / (1.0 - e2 * lat.sin().powi(2)).sqrt();
        let x = (n + h) * lat.cos() * lon.cos();
        let y = (n + h) * lat.cos() * lon.sin();
        let z = (n * (1.0 - e2) + h) * lat.sin();
        (x, y, z)
    }

    /// Build a 56-byte NAV-SOL record from geodetic position + velocity + fields.
    #[allow(clippy::too_many_arguments)]
    fn record(
        tc: i32,
        lat: f64,
        lon: f64,
        alt: f64,
        vel_cms: (i32, i32, i32),
        pacc_cm: u32,
        sacc_cms: u32,
        pdop_raw: u16,
        fix: u8,
        sats: u8,
    ) -> Vec<u8> {
        let (x, y, z) = lla_to_ecef(lat, lon, alt);
        let mut r = vec![0u8; GPS_RECORD_LEN];
        r[0..4].copy_from_slice(&tc.to_le_bytes());
        r[14] = fix;
        r[16..20].copy_from_slice(&((x * 100.0).round() as i32).to_le_bytes());
        r[20..24].copy_from_slice(&((y * 100.0).round() as i32).to_le_bytes());
        r[24..28].copy_from_slice(&((z * 100.0).round() as i32).to_le_bytes());
        r[28..32].copy_from_slice(&pacc_cm.to_le_bytes());
        r[32..36].copy_from_slice(&vel_cms.0.to_le_bytes());
        r[36..40].copy_from_slice(&vel_cms.1.to_le_bytes());
        r[40..44].copy_from_slice(&vel_cms.2.to_le_bytes());
        r[44..48].copy_from_slice(&sacc_cms.to_le_bytes());
        r[48..50].copy_from_slice(&pdop_raw.to_le_bytes());
        r[51] = sats;
        r
    }

    fn decode(bytes: &[u8]) -> Result<Option<GpsData>, DecodeError> {
        let mut g = Gatherer::default();
        g.walk(bytes, true);
        if g.gps.is_empty() {
            return Ok(None);
        }
        if g.gps.len() % GPS_RECORD_LEN != 0 {
            return Err(DecodeError::TruncatedGps);
        }
        Ok(Some(build_gps(&g.gps)))
    }

    #[test]
    fn test_ecef_lla_round_trips() {
        // A known geodetic point survives lla→ecef→lla to ~1e-7 deg / mm.
        for &(lat, lon, alt) in &[(45.045_329_7, 12.149_018_11, 43.1), (-33.8, 151.2, 5.0)] {
            let (x, y, z) = lla_to_ecef(lat, lon, alt);
            let (la, lo, al) = ecef_to_lla(x, y, z);
            assert!((la - lat).abs() < 1e-7, "lat {la} vs {lat}");
            assert!((lo - lon).abs() < 1e-7, "lon {lo} vs {lon}");
            assert!((al - alt).abs() < 1e-3, "alt {al} vs {alt}");
        }
    }

    #[test]
    fn test_decode_single_fix_fields() {
        let rec = record(
            1000,
            45.045_329_7,
            12.149_018_11,
            43.1,
            (100, 200, 50),
            3395,
            61,
            140,
            3,
            12,
        );
        let data = decode(&frame("GPS", &rec))
            .expect("decode")
            .expect("has gps");
        assert_eq!(data.len(), 1);
        let f = data.fixes()[0];
        // Position round-trips through cm-quantised ECEF, so allow ~cm error.
        assert!((f.latitude - 45.045_329_7).abs() < 1e-6);
        assert!((f.longitude - 12.149_018_11).abs() < 1e-6);
        assert!((f.altitude_m - 43.1).abs() < 2e-2);
        // speed = |(100,200,50)| cm/s / 100 = sqrt(52500)/100 m/s
        assert!((f.speed_ms - (52_500f64).sqrt() / 100.0).abs() < 1e-9);
        assert!((f.speed_kmh() - f.speed_ms * 3.6).abs() < 1e-9);
        assert!((f.position_accuracy_m - 33.95).abs() < 1e-9);
        assert!((f.velocity_accuracy_ms - 0.61).abs() < 1e-9);
        assert!((f.pdop - 1.40).abs() < 1e-9);
        assert_eq!(f.satellites, 12);
        assert_eq!(f.fix, 3);
    }

    #[test]
    fn test_channels_and_kinds() {
        let rec = record(1000, 45.0, 12.0, 40.0, (100, 0, 0), 100, 50, 100, 3, 10);
        let data = decode(&frame("GPS", &rec))
            .expect("decode")
            .expect("has gps");
        let raw = [
            "GPS Latitude",
            "GPS Longitude",
            "GPS Altitude",
            "GPS Speed",
            "GPS_Satellites",
            "GPS_Fix",
            "GPS_pDOP",
            "GPS_Position_Accuracy",
            "GPS_Velocity_Accuracy",
        ];
        for name in raw {
            assert_eq!(
                data.channel(name).unwrap().kind(),
                GpsChannelKind::Raw,
                "{name}"
            );
        }
        for name in ["GPS_InlineAcc", "GPS_LateralAcc", "GPS_Yaw_Rate"] {
            assert_eq!(
                data.channel(name).unwrap().kind(),
                GpsChannelKind::Computed,
                "{name}"
            );
        }
        assert_eq!(data.channel("GPS Latitude").unwrap().name(), "GPS Latitude");
        assert_eq!(data.channel("GPS Latitude").unwrap().unit(), "deg");
        assert_eq!(data.channel("GPS Speed").unwrap().unit(), "m/s");
        // Position/speed/accel interpolate; the discrete count/fix/pDOP are held.
        assert!(data.channel("GPS Speed").unwrap().interpolate());
        assert!(data.channel("GPS_LateralAcc").unwrap().interpolate());
        for held in ["GPS_Satellites", "GPS_Fix", "GPS_pDOP"] {
            assert!(
                !data.channel(held).unwrap().interpolate(),
                "{held} is step-held"
            );
        }
        assert_eq!(data.channels().len(), 12);
        assert!(data.channel("nope").is_none());
        assert!(!data.is_empty());
        assert_eq!(data.len(), 1);
    }

    #[test]
    fn test_multiple_records_skip_interleaved_data() {
        // Two GPS records separated by a CNF (with a CHS) and an (S data message;
        // the walk must skip the data to reach the second GPS record.
        let mut chs = vec![0u8; 112];
        chs[72] = 4; // channel 0, size 4
        let mut file = frame("CNF", &frame("CHS", &chs));
        file.extend(frame(
            "GPS",
            &record(1000, 45.0, 12.0, 40.0, (0, 0, 0), 100, 50, 100, 3, 9),
        ));
        file.extend_from_slice(&[b'(', b'S', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, b')']); // channel 0, 4 data bytes
        file.extend(frame(
            "GPS",
            &record(1100, 45.001, 12.001, 41.0, (500, 0, 0), 100, 50, 100, 3, 9),
        ));
        let data = decode(&file).expect("decode").expect("has gps");
        assert_eq!(data.len(), 2, "both GPS records decoded");
    }

    #[test]
    fn test_timecode_overflow_is_corrected() {
        // Two records whose raw timecodes wrap the low 16 bits: the second must be
        // reconstructed to 65536 + its low bits, keeping the series monotonic.
        let a = record(65_500, 45.0, 12.0, 40.0, (0, 0, 0), 100, 50, 100, 3, 9);
        let b = record(20, 45.0, 12.0, 40.0, (0, 0, 0), 100, 50, 100, 3, 9); // wrapped
        let mut file = frame("GPS", &a);
        file.extend(frame("GPS", &b));
        let data = decode(&file).expect("decode").expect("has gps");
        let t = [data.fixes()[0].timecode_ms, data.fixes()[1].timecode_ms];
        assert_eq!(t[0], 65_500.0);
        assert_eq!(t[1], 65_536.0 + 20.0, "wrapped timecode reconstructed");
    }

    #[test]
    fn test_derived_channels_zero_first_and_track_speed() {
        // Speed rises 0 → 10 m/s over 1 s → inline accel ≈ 10/9.81 g at sample 1.
        let a = record(1000, 45.0, 12.0, 40.0, (0, 0, 0), 100, 50, 100, 3, 9);
        let b = record(2000, 45.0, 12.0, 40.0, (1000, 0, 0), 100, 50, 100, 3, 9); // 10 m/s
        let mut file = frame("GPS", &a);
        file.extend(frame("GPS", &b));
        let data = decode(&file).expect("decode").expect("has gps");
        let inline = data.channel("GPS_InlineAcc").unwrap().samples();
        assert_eq!(inline[0].1, 0.0, "first inline accel is zero");
        assert!(
            (inline[1].1 - 10.0 / 9.81).abs() < 1e-9,
            "inline accel = dv/dt/g"
        );
        assert_eq!(data.channel("GPS_Yaw_Rate").unwrap().samples()[0].1, 0.0);
    }

    #[test]
    fn test_no_gps_returns_none() {
        assert!(decode(&frame("RCR", b"BOB\0")).expect("decode").is_none());
    }

    #[test]
    fn test_truncated_gps_errors() {
        // A GPS payload that is not a whole 56-byte record.
        assert!(matches!(
            decode(&frame("GPS", &[0u8; 40])),
            Err(DecodeError::TruncatedGps)
        ));
    }

    #[test]
    fn test_walk_stops_on_unsizable_data() {
        // A GPS record then an (S for an unknown channel: the walk stops but the
        // GPS gathered so far is still returned.
        let mut file = frame(
            "GPS",
            &record(1, 45.0, 12.0, 40.0, (0, 0, 0), 1, 1, 1, 3, 5),
        );
        file.extend_from_slice(&[b'(', b'S', 0, 0, 0, 0, 9, 0]); // channel 9 undefined
        let data = decode(&file).expect("decode").expect("has gps");
        assert_eq!(data.len(), 1);
    }

    #[test]
    fn test_heading_cardinal_directions() {
        // At the equator/prime meridian, ENU velocity maps to expected headings.
        // Due north (+Z at lat 0) → heading 0°.
        let north = enu_heading_deg(0.0, 0.0, 1.0, 0.0, 0.0);
        assert!(north.abs() < 1e-9, "north heading ~0, got {north}");
        // Due east (+Y at lon 0) → heading 90°.
        let east = enu_heading_deg(0.0, 1.0, 0.0, 0.0, 0.0);
        assert!((east - 90.0).abs() < 1e-9, "east heading ~90, got {east}");
    }

    /// A CNF defining channel 0 (size 4), channel 1 (size 2), and a group 0 over
    /// both (size 6) — enough to size-skip every data-message kind.
    fn cnf_with_group() -> Vec<u8> {
        let mut c0 = vec![0u8; 112];
        c0[0..2].copy_from_slice(&0u16.to_le_bytes());
        c0[72] = 4;
        let mut c1 = vec![0u8; 112];
        c1[0..2].copy_from_slice(&1u16.to_le_bytes());
        c1[72] = 2;
        let mut grp = vec![0u8; 8];
        grp[0..2].copy_from_slice(&0u16.to_le_bytes()); // group index 0
        grp[2..4].copy_from_slice(&2u16.to_le_bytes()); // 2 members
        grp[4..6].copy_from_slice(&0u16.to_le_bytes()); // channel 0 (size 4)
        grp[6..8].copy_from_slice(&1u16.to_le_bytes()); // channel 1 (size 2)
        let mut inner = frame("CHS", &c0);
        inner.extend(frame("CHS", &c1));
        inner.extend(frame("GRP", &grp));
        frame("CNF", &inner)
    }

    #[test]
    fn test_skip_every_data_kind_to_reach_gps() {
        // A group def then, between two GPS records, one message of every data
        // kind ((M, (G, and the three (c variants). Each must be size-skipped so
        // the second GPS record is still reached.
        let gps = |tc| {
            frame(
                "GPS",
                &record(tc, 45.0, 12.0, 40.0, (0, 0, 0), 1, 1, 1, 3, 5),
            )
        };
        // (M channel 0 (size 4) × 2 samples.
        let mut m = vec![b'(', b'M', 0, 0, 0, 0, 0, 0, 2, 0];
        m.extend_from_slice(&[0u8; 8]);
        m.push(b')');
        // (G group 0 (size 6).
        let mut g = vec![b'(', b'G', 0, 0, 0, 0, 0, 0];
        g.extend_from_slice(&[0u8; 6]);
        g.push(b')');
        // (c V1 channel 0 (12 + size 4), V2 (16), V3 (10).
        let mut c_v1 = vec![b'(', b'c', 0x00, 0, 0, 0x84, 0x06];
        c_v1.extend_from_slice(&[0u8; 8]);
        c_v1.push(b')');
        let mut c_v2 = vec![b'(', b'c', 0x00, 0, 0, 0x84, 0x08];
        c_v2.extend_from_slice(&[0u8; 8]);
        c_v2.push(b')');
        let c_v3 = vec![b'(', b'c', 0x01, 0, 0, 0x84, 0x02, 0, 0, b')'];

        for data in [m, g, c_v1, c_v2, c_v3] {
            let mut file = cnf_with_group();
            file.extend(gps(1000));
            file.extend(data);
            file.extend(gps(1100));
            assert_eq!(
                decode(&file).expect("decode").expect("has gps").len(),
                2,
                "second GPS record reached after skipping data"
            );
        }
    }

    #[test]
    fn test_walk_break_branches() {
        // A GPS record then a truncated header (`<h` with no room) → the walk
        // stops but keeps the GPS gathered so far.
        let mut a = frame(
            "GPS",
            &record(1, 45.0, 12.0, 40.0, (0, 0, 0), 1, 1, 1, 3, 5),
        );
        a.extend_from_slice(&[0x3C, 0x68, b'T']);
        assert_eq!(decode(&a).expect("decode").expect("gps").len(), 1);
        // A GPS record then a stray non-message byte → walk stops.
        let mut b = frame(
            "GPS",
            &record(1, 45.0, 12.0, 40.0, (0, 0, 0), 1, 1, 1, 3, 5),
        );
        b.extend_from_slice(&[0xEE, 0xEE]);
        assert_eq!(decode(&b).expect("decode").expect("gps").len(), 1);
    }

    #[test]
    fn test_malformed_group_and_unknown_data_kinds() {
        // A short GRP (< 4 bytes) is ignored without panic; the GPS still decodes.
        let mut short_grp = frame("CNF", &frame("GRP", &[0u8; 2]));
        short_grp.extend(frame(
            "GPS",
            &record(1, 45.0, 12.0, 40.0, (0, 0, 0), 1, 1, 1, 3, 5),
        ));
        assert_eq!(decode(&short_grp).expect("decode").expect("gps").len(), 1);

        // An unknown (c variant and an unknown '(x' kind each stop the walk after
        // the first GPS record (neither can be sized).
        for tail in [
            &[b'(', b'c', 0x05, 0, 0, 0x84, 0x00, 0, 0][..],
            &[b'(', b'x', 0, 0][..],
        ] {
            let mut file = frame(
                "GPS",
                &record(1, 45.0, 12.0, 40.0, (0, 0, 0), 1, 1, 1, 3, 5),
            );
            file.extend_from_slice(tail);
            assert_eq!(decode(&file).expect("decode").expect("gps").len(), 1);
        }
    }
}

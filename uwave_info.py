"""Read-only U-WAVE API v1 packets, Mitutoyo manual 99MAL216A section 6.1."""
import re
from datetime import datetime, timezone

STATUS = {'00': 'battery_low', '01': 'instrument_not_responding',
          '02': 'unregistered_transmitter', '03': 'measurement_data_loss',
          '04': 'transmitter_disconnected', '05': 'no_data',
          '50': 'request_packet_error', '51': 'end_of_search', '99': 'data_cancel'}
STATES = ['unregistered', 'disconnected', 'connected', 'editing',
          'editing_source', 'editing_destination']


def timestamp():
    return datetime.now(timezone.utc).isoformat()


def parse_packet(raw):
    p = {'type': 'raw', 'raw': raw}
    if re.fullmatch(r'RI1(?:\d{2}|FF)\d{10}\d{2}[0-9][01]\d{48}', raw):
        noise = [int(raw[i:i+3]) for i in range(19, 67, 3)]
        if not 11 <= int(raw[15:17]) <= 25 or any(n > 255 for n in noise):
            return p
        p.update(type='receiver_info', receiverDeviceId=raw[5:15],
                 groupId=None if raw[3:5] == 'FF' else raw[3:5],
                 factoryDefault=raw[3:5] == 'FF', bandId=raw[15:17],
                 dataLossCheckLevel=int(raw[17]), duplicateReceiver=raw[18] == '1',
                 noiseByBand={str(11+i): None if n == 255 else n for i, n in enumerate(noise[:15])},
                 noiseSource='stored_scan_not_live', reservedValue=noise[15])
    elif re.fullmatch(r'TI1[0-5](?:\d{2}|FF)(?:\d{2}|FF)\d{10}\d{2}[01]', raw):
        if not 11 <= int(raw[18:20]) <= 25:
            return p
        p.update(type='transmitter_info', transmitterDeviceId=raw[8:18],
                 transmitterChannel=None if raw[4:6] == 'FF' else raw[4:6],
                 groupId=None if raw[6:8] == 'FF' else raw[6:8], bandId=raw[18:20],
                 transmitterStateCode=raw[3], transmitterState=STATES[int(raw[3])],
                 measurementMode='button' if raw[20] == '0' else 'event')
    elif re.fullmatch(r'ST1(?:\d{2}|FF)(?:\d{2}|FF)(?:\d{10}|F{10})\d{2}', raw):
        p.update(type='status', groupId=None if raw[3:5] == 'FF' else raw[3:5],
                 transmitterChannel=None if raw[5:7] == 'FF' else raw[5:7],
                 transmitterDeviceId=None if raw[7:17] == 'F'*10 else raw[7:17],
                 statusCode=raw[17:19], statusMeaning=STATUS.get(raw[17:19], 'unknown'))
    else:
        m = re.fullmatch(r'DT1(\d{2})(\d{2})([+-]\d+\.\d+)([MI0])', raw)
        if m:
            p.update(type='measurement', groupId=m[1], transmitterChannel=m[2],
                     channel=raw[2:7], value=float(m[3]), unit=m[4],
                     unitName={'M': 'mm', 'I': 'inch', '0': None}[m[4]])
    if p['type'] != 'raw':
        p['apiVersion'] = '1'
    return p


class Inventory:
    def __init__(self, refresh=60):
        self.receiver = None
        self.transmitters = {}
        self.refresh = refresh
        self.pending = None
        self.next_at = 0
        self.phase = 'receiver'
        self.channel = 0
        self.complete = False
        self.error = None
        self.revision = 0

    def finish(self, now, error=None):
        self.pending = None
        self.phase = 'idle'
        self.next_at = now + self.refresh
        self.complete = error is None
        self.error = error
        self.revision += 1

    def command(self, now):
        if self.pending:
            if now < self.pending['deadline']:
                return None
            if self.pending['attempts'] >= 3:
                self.finish(now, 'query_timeout')
                return None
            self.pending['attempts'] += 1
            self.pending['deadline'] = now + 3
            return self.pending['bytes']
        if now < self.next_at:
            return None
        if self.phase == 'idle':
            self.phase = 'receiver'
        if self.phase == 'receiver':
            self.complete = False
            self.error = None
            group = (self.receiver or {}).get('groupId') or '00'
            command = f'IR1000{group}0\r'
        else:
            command = f'IR11{self.channel:02d}{self.receiver["groupId"]}1\r'
        self.pending = {'bytes': command.encode('ascii'), 'deadline': now + 3, 'attempts': 1}
        return self.pending['bytes']

    def accept(self, p, now):
        kind = p['type']
        if kind == 'receiver_info':
            changed = self.receiver and any(self.receiver.get(k) != p.get(k)
                                           for k in ('receiverDeviceId', 'groupId', 'bandId'))
            self.receiver = dict(p, observedAt=timestamp())
            if changed:
                self.transmitters.clear()
            if self.phase == 'receiver' and self.pending:
                self.transmitters.clear()
                self.pending = None
                self.channel = 0
                self.phase = 'transmitters'
                self.next_at = now + .25
                if p['groupId'] is None:
                    self.finish(now, 'factory_default')
        elif kind == 'transmitter_info' and p['transmitterChannel'] is not None:
            self.transmitters[(p['groupId'], p['transmitterChannel'])] = dict(p, observedAt=timestamp())
            if (self.phase == 'transmitters' and self.pending and
                    p['groupId'] == self.receiver['groupId'] and
                    int(p['transmitterChannel']) >= self.channel):
                self.channel = int(p['transmitterChannel']) + 1
                self.pending = None
                self.next_at = now + .25
                if self.channel > 99:
                    self.finish(now)
        elif kind == 'status' and self.pending:
            if (self.phase == 'transmitters' and p['statusCode'] == '51' and
                    p['groupId'] == self.receiver['groupId'] and
                    p['transmitterChannel'] == f'{self.channel:02d}'):
                self.finish(now)
            elif p['statusCode'] == '50':
                self.finish(now, 'request_packet_error')

    def enrich(self, p):
        result = dict(p)
        r = self.receiver or {}
        result.setdefault('receiverDeviceId', r.get('receiverDeviceId'))
        result['receiverInfoObservedAt'] = r.get('observedAt')
        result['receiverBandId'] = r.get('bandId')
        t = self.transmitters.get((p.get('groupId'), p.get('transmitterChannel')), {})
        result.setdefault('transmitterDeviceId', t.get('transmitterDeviceId'))
        result['transmitterInfoObservedAt'] = t.get('observedAt')
        return result

    def snapshot(self):
        return {'type': 'inventory', 'complete': self.complete, 'error': self.error,
                'receiverInfo': self.receiver, 'transmitters': list(self.transmitters.values())}

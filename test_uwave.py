import unittest
from unittest.mock import patch
from uwave_info import parse_packet, Inventory

RI = 'RI10010000613582391' + '255' * 16
TI = 'TI1205000123456789230'


class ProtocolTests(unittest.TestCase):
    def test_partial_output_write(self):
        from uwave_aggregator import Output
        out = Output()
        out.add({'type': 'test'})
        original = out.queue[0]
        with patch('os.write', return_value=3):
            out.flush(1)
        self.assertEqual(out.queue[0], original[3:])
        self.assertEqual(out.size, len(original) - 3)

    def test_refresh_clears_old_transmitter_mapping(self):
        inv = Inventory()
        inv.command(0)
        inv.accept(parse_packet(RI), 1)
        inv.command(2)
        inv.accept(parse_packet(TI), 3)
        inv.command(4)
        inv.accept(parse_packet('ST10006FFFFFFFFFF51'), 5)
        inv.command(66)
        inv.accept(parse_packet(RI), 67)
        self.assertIsNone(inv.enrich(parse_packet('DT10005+00000020.06M'))['transmitterDeviceId'])

    def test_receiver(self):
        p = parse_packet(RI)
        self.assertEqual(p['receiverDeviceId'], '1000061358')
        self.assertEqual(p['bandId'], '23')
        self.assertTrue(p['duplicateReceiver'])
        self.assertEqual(p['noiseByBand']['11'], None)
        self.assertEqual(len(p['noiseByBand']), 15)

    def test_transmitter(self):
        p = parse_packet(TI)
        self.assertEqual(p['transmitterDeviceId'], '0123456789')
        self.assertEqual(p['transmitterChannel'], '05')
        self.assertEqual(p['transmitterState'], 'connected')
        self.assertEqual(p['measurementMode'], 'button')

    def test_measurement_compatibility(self):
        p = parse_packet('DT10005+00000020.06M')
        self.assertEqual(p['channel'], '10005')
        self.assertEqual(p['groupId'], '00')
        self.assertEqual(p['transmitterChannel'], '05')
        self.assertEqual(p['value'], 20.06)
        self.assertEqual(p['unit'], 'M')
        self.assertEqual(p['unitName'], 'mm')

    def test_status_error_not_ready(self):
        p = parse_packet('ST100FFFFFFFFFFFF50')
        self.assertEqual(p['statusCode'], '50')
        self.assertEqual(p['statusMeaning'], 'request_packet_error')
        self.assertIsNone(p['transmitterDeviceId'])

    def test_invalid(self):
        for raw in ['RI1', RI + 'x', 'TI1garbage', 'DT10005+20.06Mgarbage']:
            self.assertEqual(parse_packet(raw)['type'], 'raw')

    def test_read_only_poll_and_identity(self):
        inv = Inventory()
        self.assertEqual(inv.command(0), b'IR1000000\r')
        inv.accept(parse_packet(RI), 1)
        self.assertEqual(inv.command(2), b'IR1100001\r')
        inv.accept(parse_packet(TI), 3)
        self.assertEqual(inv.command(4), b'IR1106001\r')
        p = inv.enrich(parse_packet('DT10005+00000020.06M'))
        self.assertEqual(p['receiverDeviceId'], '1000061358')
        self.assertEqual(p['transmitterDeviceId'], '0123456789')
        inv.accept(parse_packet('ST10006FFFFFFFFFF51'), 5)
        self.assertTrue(inv.complete)
        self.assertIsNone(inv.command(6))

    def test_timeout_and_unknown_identity(self):
        inv = Inventory()
        inv.command(0)
        self.assertIsNone(inv.command(1))
        self.assertEqual(inv.command(4), b'IR1000000\r')
        inv.command(8)
        self.assertIsNone(inv.command(12))
        self.assertEqual(inv.error, 'query_timeout')
        self.assertIsNone(inv.enrich(parse_packet('DT10005+00000020.06M'))['receiverDeviceId'])


if __name__ == '__main__':
    unittest.main()

import importlib.util
import json
import pathlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('adapter', pathlib.Path(__file__).parents[1] / 'bin/legacy_to_bids.py')
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)


class AdapterTests(unittest.TestCase):
    def fixture(self, root):
        source = root / 'legacy'; (source / 'selection').mkdir(parents=True)
        (source / 'selection/input_selection.json').write_text(json.dumps({'t1_dwell': 7.1e-6, 't2_dwell': 2.1e-6}))
        items = {'T1w_MPR': {'SeriesNumber': 12}, 'T2w_SPC': {'SeriesNumber': 13},
                 'SpinEchoFieldMap_AP_struct': {'SeriesNumber': 6, 'PhaseEncodingDirection': 'j-'},
                 'SpinEchoFieldMap_PA_struct': {'SeriesNumber': 9, 'PhaseEncodingDirection': 'j'},
                 'dMRI_set1_AP': {'SeriesNumber': 20}, 'dMRI_set1_PA': {'SeriesNumber': 21}}
        for name, meta in items.items():
            (source / (name + '.nii.gz')).write_bytes(b'fixture')
            (source / (name + '.json')).write_text(json.dumps(meta))
            if name.startswith('dMRI'):
                (source / (name + '.bval')).write_text('0 1000')
                (source / (name + '.bvec')).write_text('0 1\n0 0\n0 0\n')
        return source

    def test_preserves_original_json_and_links_gradients(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp); source = self.fixture(root)
            original = (source / 'T1w_MPR.json').read_bytes()
            result = module.adapt(source, root / 'bids', 'SITE_HARP_001')
            self.assertEqual(original, (source / 'T1w_MPR.json').read_bytes())
            self.assertEqual(2, len(result['metadata_derivations']))
            bvals = list((root / 'bids').glob('sub-*/ses-*/dwi/*.bval'))
            self.assertEqual(2, len(bvals))
            self.assertEqual('0 1000', bvals[0].read_text())

    def test_unknown_fieldmap_direction_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp); source = self.fixture(root)
            (source / 'SpinEchoFieldMap_AP_struct.json').write_text('{"SeriesNumber":6}')
            with self.assertRaises(ValueError):
                module.adapt(source, root / 'bids', 'SITE_HARP_001')

    def test_existing_dwell_is_not_replaced(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp); source = self.fixture(root)
            (source / 'T1w_MPR.json').write_text('{"DwellTime":0.000009}')
            result = module.adapt(source, root / 'bids', 'SITE_HARP_001')
            t1 = next((root / 'bids').glob('sub-*/ses-*/anat/*_T1w.json'))
            self.assertEqual(9e-6, json.loads(t1.read_text())['DwellTime'])
            self.assertEqual(1, len(result['metadata_derivations']))


if __name__ == '__main__':
    unittest.main()

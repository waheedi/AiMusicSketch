"""Fast offline tests of long-form scheduling and joins; no model is loaded."""
import math
import unittest
import numpy as np
import audio_worker as worker


class ContinuationTests(unittest.TestCase):
    def test_context_budget_and_exact_duration(self):
        rate, hop = 32000, 640
        for seconds in [1, 17, 17.01, 29, 29.01, 30.25, 60, 120.013, 300]:
            for reference in [0, 0.26, 8, 12]:
                total = round(seconds * rate)
                prefix = math.ceil(reference * rate / hop) * hop
                plan = worker.section_plan(total, rate, hop, prefix)
                self.assertEqual(sum(p["added_frames"] for p in plan), total)
                for p in plan:
                    self.assertLessEqual(p["aligned_context"] + p["new_frames"], 29 * rate)
                    self.assertEqual(p["aligned_context"] % hop, 0)
                    self.assertGreater(p["added_frames"], 0)
                if seconds + reference > 29:
                    self.assertGreater(len(plan), 1)

    def test_generated_sections_use_previous_audio_and_crossfade(self):
        rate, hop = 1000, 20
        prefix = np.full(1000, 0.9, dtype=np.float32)
        calls = []

        def generate(context, frames, index, count, completed):
            calls.append((context.copy(), completed))
            self.assertLessEqual(len(context) + frames, 29 * rate)
            return np.full(frames, index * 0.1, dtype=np.float32)

        output, count = worker.continue_sections(60013, rate, hop, prefix, generate, lambda *args: None)
        self.assertEqual(len(output), 60013)
        self.assertEqual(count, 3)
        np.testing.assert_array_equal(calls[0][0], prefix)
        np.testing.assert_allclose(calls[1][0], 0.1)
        np.testing.assert_allclose(calls[2][0], 0.2)
        self.assertAlmostEqual(output[0], 0.1)  # no reconstructed reference included
        self.assertAlmostEqual(output[-1], 0.3)  # fresh section, not a repeated loop
        self.assertLess(float(np.max(np.abs(np.diff(output)))), 0.006)
        np.testing.assert_allclose(prefix, 0.9)  # input remains untouched

    def test_reference_free_generation_gets_context_after_first_section(self):
        calls = []
        def generate(context, frames, *args):
            calls.append(len(context))
            return np.full(frames, 0.2, dtype=np.float32)
        output, _ = worker.continue_sections(30001, 1000, 20, None, generate, lambda *args: None)
        self.assertEqual(calls, [0, 8000])
        self.assertEqual(len(output), 30001)

    def test_short_final_section_and_failure_are_not_silently_padded(self):
        def generate(context, frames, *args):
            return np.ones(frames, dtype=np.float32) * 0.1
        output, count = worker.continue_sections(29001, 1000, 20, None, generate, lambda *args: None)
        self.assertEqual(len(output), 29001)
        self.assertEqual(count, 2)
        for bad in [lambda n: np.zeros(n), lambda n: np.full(n, np.nan), lambda n: np.ones(n - 1)]:
            with self.assertRaises(ValueError):
                worker.continue_sections(1000, 1000, 20, None,
                    lambda context, frames, *args: bad(frames), lambda *args: None)
        for bad in [0, 999, 300001]:
            with self.assertRaises(ValueError):
                worker.section_plan(bad, 1000, 20)


if __name__ == "__main__":
    unittest.main()

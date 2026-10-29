import importlib.util
from pathlib import Path
import tempfile
import unittest

spec=importlib.util.spec_from_file_location("bridge",Path(__file__).resolve().parents[1]/"bridge/bridge.py")
bridge=importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)

class Tests(unittest.TestCase):
    def test_whitelist_rejects_executable_and_out_of_range_fields(self):
        for value in ({"code":"os.execute(...)"},{"radius":500},{"radius":True},{"guard":"true"},{"recipe":"dragonpie"}):
            with self.assertRaises(ValueError): bridge.validate(value)

    def test_disabled_does_not_call_transport(self):
        def fail(_): self.fail("Unexpected API call")
        with self.assertRaises(ValueError): bridge.Planner(transport=fail).plan("守着农田",{"guard":False})

    def test_cache_and_fixed_small_nonthinking_request(self):
        calls=[]
        def fake(payload): calls.append(payload);return {"policy":{"guard":True,"harvest":True}}
        p=bridge.Planner(True,transport=fake)
        first=p.plan("守着农田顺便收菜",{"guard":False})
        second=p.plan("守着农田顺便收菜",{"guard":False})
        self.assertEqual(first["source"],"deepseek")
        self.assertEqual(second["source"],"cache")
        self.assertEqual(len(calls),1)
        self.assertEqual(calls[0]["thinking"],{"type":"disabled"})
        self.assertEqual(calls[0]["max_tokens"],256)
        self.assertEqual(len(calls[0]["messages"]),2)

    def test_budget_persists_and_blocks_calls(self):
        with tempfile.TemporaryDirectory() as tmp:
            ledger=Path(tmp)/"usage.json"
            p=bridge.Planner(True,10000,ledger,lambda _: {"policy":{"paused":True}})
            p.plan("先歇会",{"paused":False})
            restored=bridge.Planner(True,p.used,ledger,lambda _: self.fail("Over budget call"))
            with self.assertRaises(ValueError): restored.plan("停下来",{"paused":False})

    def test_failed_call_is_not_retried_and_keeps_budget(self):
        calls=[]
        def failure(payload): calls.append(payload);raise TimeoutError()
        p=bridge.Planner(True,transport=failure)
        with self.assertRaises(TimeoutError): p.plan("歇会",{"paused":False})
        self.assertEqual(len(calls),1)
        self.assertGreater(p.used,0)

    def test_model_code_and_unknown_fields_are_rejected(self):
        p=bridge.Planner(True,transport=lambda _: {"policy":{"exec":"return 1"}})
        with self.assertRaises(ValueError): p.plan("工作",{"paused":False})

if __name__=="__main__": unittest.main()

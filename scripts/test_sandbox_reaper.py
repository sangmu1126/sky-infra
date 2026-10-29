"""Only expired owned build VMs may be terminated by the independent sweeper."""
import copy
import unittest
from datetime import UTC, datetime, timedelta
from unittest.mock import Mock

from sandbox_reaper import reap


class ReaperTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime(2026, 10, 30, tzinfo=UTC)
        self.env = {"SKY_SANDBOX_PROFILE": "sky-test", "SKY_SANDBOX_VPC": "vpc-test",
                    "SKY_SANDBOX_GROUP": "sg-test", "SKY_ACCOUNT_ID": "123456789012",
                    "SKY_MAX_LIFETIME": "900", "SKY_REVIEW_QUEUE": "https://queue"}
        self.instance = {"InstanceId": "i-test", "VpcId": "vpc-test", "SecurityGroups": [{"GroupId": "sg-test"}],
                         "LaunchTime": self.now - timedelta(seconds=901), "Tags": [
                             {"Key": "app", "Value": "sky"}, {"Key": "sky:SandboxProfile", "Value": "sky-test"},
                             {"Key": "sky:DeadlineEpoch", "Value": str(int(self.now.timestamp()) - 1)}]}
        self.ec2, self.queue = Mock(), Mock()
        self.ec2.describe_instances.return_value = {"Reservations": [{"OwnerId": "123456789012", "Instances": [self.instance]}]}

    def run_reaper(self):
        return reap({"mode": "sweep"}, ec2=self.ec2, queue=self.queue, environment=self.env, now=self.now)

    def test_expired_termination_is_scoped_and_requires_review(self):
        result = self.run_reaper()
        self.ec2.terminate_instances.assert_called_once_with(InstanceIds=["i-test"])
        self.assertFalse(result["security_clearance"])
        self.assertIn('"operator_review_required": true', self.queue.send_message.call_args.kwargs["MessageBody"])

    def test_live_vm_is_untouched(self):
        self.instance["LaunchTime"] = self.now
        self.instance["Tags"][-1]["Value"] = str(int(self.now.timestamp()) + 800)
        self.assertEqual(self.run_reaper()["terminated"], 0)
        self.ec2.terminate_instances.assert_not_called()
        self.queue.send_message.assert_not_called()

    def test_invalid_deadline_cannot_buy_unlimited_lifetime(self):
        self.instance["Tags"][-1]["Value"] = "9999999999999999"
        self.assertEqual(self.run_reaper()["terminated"], 1)

    def test_foreign_scope_and_incomplete_inventory_never_mutate(self):
        baseline = copy.deepcopy(self.ec2.describe_instances.return_value)
        for change in ("owner", "group", "profile", "pages"):
            self.ec2.describe_instances.return_value = copy.deepcopy(baseline)
            response = self.ec2.describe_instances.return_value
            instance = response["Reservations"][0]["Instances"][0]
            if change == "owner":
                response["Reservations"][0]["OwnerId"] = "999999999999"
            elif change == "group":
                instance["SecurityGroups"].append({"GroupId": "sg-other"})
            elif change == "profile":
                instance["Tags"][1]["Value"] = "sky-other"
            else:
                response["NextToken"] = "still-more"
            with self.assertRaises(ValueError):
                self.run_reaper()
            self.ec2.terminate_instances.assert_not_called()


if __name__ == "__main__":
    unittest.main()

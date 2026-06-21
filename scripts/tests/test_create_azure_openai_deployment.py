import subprocess
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = PROJECT_ROOT / "scripts" / "create-azure-openai-deployment.sh"


class CreateAzureOpenAIDeploymentScriptTests(unittest.TestCase):
    def test_help_prints_header_without_script_body(self):
        result = subprocess.run(
            ["/bin/bash", str(SCRIPT), "--help"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Create an Azure OpenAI model deployment", result.stdout)
        self.assertIn("Environment fallbacks:", result.stdout)
        self.assertNotIn("set -euo pipefail", result.stdout)

    def test_dry_run_prints_reproducible_az_command_with_defaults(self):
        result = subprocess.run(
            [
                "/bin/bash",
                str(SCRIPT),
                "--resource-group",
                "lungfish-rg",
                "--account-name",
                "lungfish-ai",
                "--deployment-name",
                "gpt-5-mini",
                "--model-name",
                "gpt-5-mini",
                "--model-version",
                "2025-08-07",
                "--dry-run",
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("az cognitiveservices account deployment create", result.stdout)
        self.assertIn("--resource-group lungfish-rg", result.stdout)
        self.assertIn("--name lungfish-ai", result.stdout)
        self.assertIn("--deployment-name gpt-5-mini", result.stdout)
        self.assertIn("--model-name gpt-5-mini", result.stdout)
        self.assertIn("--model-version 2025-08-07", result.stdout)
        self.assertIn("--model-format OpenAI", result.stdout)
        self.assertIn("--sku-name Standard", result.stdout)
        self.assertIn("--sku-capacity 1", result.stdout)

    def test_missing_required_model_version_fails_before_calling_az(self):
        result = subprocess.run(
            [
                "/bin/bash",
                str(SCRIPT),
                "--resource-group",
                "lungfish-rg",
                "--account-name",
                "lungfish-ai",
                "--model-name",
                "gpt-5-mini",
                "--dry-run",
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

        self.assertEqual(result.returncode, 64)
        self.assertIn("--model-version is required", result.stderr)


if __name__ == "__main__":
    unittest.main()

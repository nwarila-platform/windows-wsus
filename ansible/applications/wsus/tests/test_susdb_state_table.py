"""Offline coverage for the WSUS role's recovery and content-state contracts."""

from pathlib import Path
import unittest

from jinja2 import Environment
import yaml


TASK_FILE = Path(__file__).parents[1] / "tasks" / "present_windows.yml"
ROLE_BLOCK_TASK = "INFO | Entering OS Tasks (present_windows - wsus)"
WID_SERVICE_TASK = "MAIN | Ensure WID Service Is Automatic And Running Before SUSDB Probes"
PREPOST_CLASSIFIER_TASK = "MAIN | Classify The Pre-Postinstall SUSDB Action"
PREPOST_GUARD_TASK = "MAIN | Refuse Ambiguous SUSDB Authority Before Post-Installation Repair"
PREPOST_ADOPTION_TASK = "MAIN | Adopt And Verify The Preserved SUSDB Before Post-Installation Repair"
POSTINSTALL_TASK = "MAIN | Run WSUS Post-Installation (WID, content on F:)"
CLASSIFIER_TASK = "MAIN | Classify The SUSDB Recovery Action"
SUSDB_HEALTH_TASK = "MAIN | Verify SUSDB Relocation Health"
SUSDB_CLEANUP_TASK = "MAIN | Remove SUSDB Originals From System Volume"
WSUS_SERVICES_TASK = "MAIN | Ensure WSUS Services Are Running After SUSDB Convergence"
CONTENT_RECONCILE_TASK = "MAIN | Reconcile The WSUS Content Location"
CONTENT_USERS_ACL_TASK = "MAIN | Grant Users Browse Access On The Content Root"
CONTENT_ACL_TASK = "MAIN | Grant WSUS Service Rights On The Content Cache"
LANGUAGE_TASK = "MAIN | Restrict WSUS Update Languages"
UPSTREAM_TASK = "MAIN | Configure Upstream WSUS Source"
BOOTSTRAP_TASK = "MAIN | Bootstrap WSUS Category Sync To Terminal Success"
WSUSPOOL_TASK = "MAIN | Tune WsusPool Application Pool"
TLS_STORE_PROBE_TASK = "MAIN | Probe The Pinned Certificate In The Machine Store"
TLS_PFX_VALIDATE_TASK = "MAIN | Validate The PFX Before Import"
TLS_BINDING_TASK = "MAIN | Bind The Pinned Certificate To The WSUS HTTPS Endpoint"
TLS_CONFIGURESSL_TASK = "MAIN | Require SSL On The Client-Facing WSUS Endpoints"
TLS_PRE_API_LISTENER_TASK = "MAIN | Reconcile Existing WSUS HTTPS Listener Before API Access"
TLS_LISTENER_TASK = "MAIN | Activate And Verify The WSUS HTTPS Listener"
TLS_LIVE_TASK = "VERIFY | Complete A Live HTTPS Request To The WSUS Client Endpoint"
RUNTIME_VERIFY_TASK = "VERIFY | Assert The Complete WSUS Runtime Contract"


def walk_tasks(tasks):
    """Yield tasks recursively through Ansible block/rescue/always lists."""
    for task in tasks:
        yield task
        for section in ("block", "rescue", "always"):
            yield from walk_tasks(task.get(section, []))


def classifier_template():
    tasks = yaml.safe_load(TASK_FILE.read_text(encoding="utf-8"))
    task = next(item for item in walk_tasks(tasks) if item.get("name") == CLASSIFIER_TASK)
    return task["ansible.builtin.set_fact"]["__susdb_recovery_action__"]


def prepost_classifier_template():
    tasks = yaml.safe_load(TASK_FILE.read_text(encoding="utf-8"))
    task = next(item for item in walk_tasks(tasks) if item.get("name") == PREPOST_CLASSIFIER_TASK)
    return task["ansible.builtin.set_fact"]["__prepostinstall_action__"]


def named_task(name):
    """Return one recursively nested task by its exact name."""
    tasks = yaml.safe_load(TASK_FILE.read_text(encoding="utf-8"))
    matches = [item for item in walk_tasks(tasks) if item.get("name") == name]
    if len(matches) != 1:
        raise AssertionError(f"expected one task named {name!r}, found {len(matches)}")
    return matches[0]


def powershell_script(task):
    """Return the sole inline PowerShell source regardless of safe transport."""
    scripts = []
    win_shell = task.get("ansible.windows.win_shell")
    if isinstance(win_shell, str):
        scripts.append(win_shell)
    win_powershell = task.get("ansible.windows.win_powershell")
    if isinstance(win_powershell, dict) and isinstance(win_powershell.get("script"), str):
        scripts.append(win_powershell["script"])
    if len(scripts) != 1:
        raise AssertionError(
            f"expected one inline PowerShell script in {task.get('name')!r}, found {len(scripts)}"
        )
    return scripts[0]


def normalize(location, source_count, target_count):
    """Mirror the two safe pre-classification cleanup rules."""
    if location == "source" and source_count == 2 and target_count > 0:
        target_count = 0
    elif location == "absent" and source_count == 2 and target_count == 1:
        target_count = 0
    return source_count, target_count


class PowerShellTransportContractTest(unittest.TestCase):
    def test_remaining_win_shell_commands_stay_below_the_safe_createprocess_budget(self):
        tasks = list(walk_tasks(yaml.safe_load(TASK_FILE.read_text(encoding="utf-8"))))
        role_vars = named_task(ROLE_BLOCK_TASK)["vars"]
        helpers = {
            name: role_vars[name]
            for name in (
                "__wsus_api_invoker__",
                "__wsus_https_listener_reconciler__",
            )
        }
        input_encoding_prelude = (
            "[Console]::InputEncoding = New-Object Text.UTF8Encoding `$false; "
        )
        fixed_command_headroom = 512
        measurements = []

        for task in tasks:
            for module_name in (
                "ansible.windows.win_shell",
                "community.windows.win_shell",
                "win_shell",
            ):
                module_value = task.get(module_name)
                if module_value is None:
                    continue
                script = (
                    module_value.get("cmd")
                    if isinstance(module_value, dict)
                    else module_value
                )
                self.assertIsInstance(
                    script,
                    str,
                    f"unsupported {module_name} form in {task.get('name')}",
                )
                expanded = script
                for helper_name, helper_source in helpers.items():
                    expanded = expanded.replace(
                        "{{ " + helper_name + " }}", helper_source
                    )
                    self.assertNotIn(
                        helper_name,
                        expanded,
                        f"unexpanded shared helper in {task.get('name')}",
                    )
                self.assertNotIn("{{", expanded, task.get("name"))
                self.assertNotIn("{%", expanded, task.get("name"))
                payload_bytes = len(
                    (input_encoding_prelude + expanded).encode("utf-16le")
                )
                encoded_characters = 4 * ((payload_bytes + 2) // 3)
                conservative_command_characters = (
                    encoded_characters + fixed_command_headroom
                )
                measurements.append(
                    (conservative_command_characters, task.get("name"))
                )
                self.assertLess(
                    conservative_command_characters,
                    30_000,
                    (
                        f"{task.get('name')} expands to at least "
                        f"{conservative_command_characters} command characters; "
                        "use win_powershell instead of risking CreateProcessW rc206"
                    ),
                )

        self.assertTrue(measurements)
        largest = max(measurements)
        self.assertEqual(largest[1], BOOTSTRAP_TASK)


class SusdbStateTableTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.template = Environment(autoescape=False).from_string(classifier_template())

    def classify(self, location, source_count, target_count):
        source_count, target_count = normalize(location, source_count, target_count)
        return self.template.render(
            __susdb_location__=location,
            __susdb_source_count__=source_count,
            __susdb_target_count__=target_count,
        ).strip()

    def test_allowed_authority_states(self):
        expected = {
            ("source", 2, 0): "rebuild_from_source",
            ("source", 2, 1): "rebuild_from_source",
            ("source", 2, 2): "rebuild_from_source",
            ("target", 0, 2): "converged",
            ("target", 1, 2): "converged",
            ("target", 2, 2): "converged",
            ("absent", 2, 0): "copy_from_source",
            ("absent", 2, 1): "copy_from_source",
            ("absent", 0, 2): "attach_target",
        }
        for state, action in expected.items():
            with self.subTest(state=state):
                self.assertEqual(self.classify(*state), action)

    def test_ambiguous_or_incomplete_states_fail_closed(self):
        allowed = {
            ("source", 2, 0),
            ("source", 2, 1),
            ("source", 2, 2),
            ("target", 0, 2),
            ("target", 1, 2),
            ("target", 2, 2),
            ("absent", 2, 0),
            ("absent", 2, 1),
            ("absent", 0, 2),
        }
        for location in ("source", "target", "absent", "other"):
            for source_count in range(3):
                for target_count in range(3):
                    state = (location, source_count, target_count)
                    if state in allowed:
                        continue
                    with self.subTest(state=state):
                        self.assertEqual(self.classify(*state), "invalid")

        # This is the destructive regression: without an attachment, neither complete pair
        # is authoritative, so the target must never be chosen merely because it exists.
        self.assertEqual(self.classify("absent", 2, 2), "invalid")

    def test_target_authority_survives_every_source_cleanup_kill_boundary(self):
        # Source cleanup is a two-item loop. A kill can occur before either deletion, between
        # them, or after both. In all three states the attached complete target is authoritative;
        # the next run health-checks it and safely removes whatever source remnants remain.
        for remaining_source_files in (2, 1, 0):
            with self.subTest(remaining_source_files=remaining_source_files):
                self.assertEqual(
                    self.classify("target", remaining_source_files, 2),
                    "converged",
                )

        cleanup = named_task(SUSDB_CLEANUP_TASK)
        self.assertEqual(cleanup["loop"], ["SUSDB.mdf", "SUSDB_log.ldf"])
        tasks = yaml.safe_load(TASK_FILE.read_text(encoding="utf-8"))
        ordered_names = [item.get("name") for item in walk_tasks(tasks)]
        self.assertLess(
            ordered_names.index(SUSDB_HEALTH_TASK),
            ordered_names.index(SUSDB_CLEANUP_TASK),
        )


class PrePostinstallSusdbAuthorityTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.template = Environment(autoescape=False).from_string(prepost_classifier_template())

    def classify(self, location, source_count, target_count):
        return self.template.render(
            __prepostinstall_location__=location,
            __prepostinstall_source_count__=source_count,
            __prepostinstall_target_count__=target_count,
        ).strip()

    def test_authority_matrix_fails_closed_before_postinstall(self):
        expected = {
            ("absent", 0, 0): "fresh",
            ("absent", 0, 2): "adopt_target",
            ("target", 0, 2): "target_attached",
            ("target", 1, 2): "target_attached",
            ("target", 2, 2): "target_attached",
            ("source", 2, 0): "source_attached",
        }
        for location in ("absent", "source", "target", "other"):
            for source_count in range(3):
                for target_count in range(3):
                    state = (location, source_count, target_count)
                    with self.subTest(state=state):
                        self.assertEqual(
                            self.classify(*state),
                            expected.get(state, "invalid"),
                        )

        # These are the two data-loss boundaries: postinstall must neither create a fresh source
        # over a sole preserved target nor choose between two competing complete pairs.
        self.assertEqual(self.classify("absent", 0, 2), "adopt_target")
        self.assertEqual(self.classify("absent", 2, 2), "invalid")
        self.assertEqual(self.classify("source", 2, 2), "invalid")

    def test_adoption_is_health_gated_and_precedes_postinstall(self):
        adoption = named_task(PREPOST_ADOPTION_TASK)
        script = adoption["ansible.windows.win_shell"]
        self.assertIn("CREATE DATABASE SUSDB", script)
        self.assertIn("$state -ne 'ONLINE'", script)
        self.assertIn("$readOnly -ne 0", script)
        self.assertIn("$offTarget.Count -gt 0", script)
        self.assertEqual(
            adoption["changed_when"],
            "__prepostinstall_adoption__.stdout | trim == 'adopted-target'",
        )

        tasks = yaml.safe_load(TASK_FILE.read_text(encoding="utf-8"))
        ordered_names = [item.get("name") for item in walk_tasks(tasks)]
        self.assertLess(
            ordered_names.index(PREPOST_CLASSIFIER_TASK),
            ordered_names.index(PREPOST_GUARD_TASK),
        )
        self.assertLess(
            ordered_names.index(PREPOST_GUARD_TASK),
            ordered_names.index(POSTINSTALL_TASK),
        )
        self.assertLess(
            ordered_names.index(PREPOST_ADOPTION_TASK),
            ordered_names.index(POSTINSTALL_TASK),
        )


class WidServiceContractTest(unittest.TestCase):
    def test_service_is_reconciled_before_every_sql_connection_and_reverified(self):
        service = named_task(WID_SERVICE_TASK)["ansible.windows.win_service"]
        self.assertEqual(
            service,
            {
                "name": "MSSQL$MICROSOFT##WID",
                "start_mode": "auto",
                "state": "started",
            },
        )

        tasks = list(walk_tasks(yaml.safe_load(TASK_FILE.read_text(encoding="utf-8"))))
        service_index = next(
            index for index, task in enumerate(tasks) if task.get("name") == WID_SERVICE_TASK
        )
        sql_connection_indices = [
            index
            for index, task in enumerate(tasks)
            if "SqlConnection($env:WID_CONN)" in task.get("ansible.windows.win_shell", "")
        ]
        self.assertTrue(sql_connection_indices)
        for sql_connection_index in sql_connection_indices:
            with self.subTest(sql_task=tasks[sql_connection_index].get("name")):
                self.assertLess(service_index, sql_connection_index)

        verifier = powershell_script(named_task(RUNTIME_VERIFY_TASK))
        self.assertIn("Get-CimInstance -ClassName Win32_Service", verifier)
        self.assertIn('Name = "MSSQL$MICROSOFT##WID"', verifier)
        self.assertIn("$widService.StartMode -ne 'Auto'", verifier)
        self.assertIn("$widService.State -ne 'Running'", verifier)


class ContentStateContractTest(unittest.TestCase):
    def test_reconcile_uses_copying_movecontent_and_fails_closed_on_split_brain(self):
        task = named_task(CONTENT_RECONCILE_TASK)
        script = task["ansible.windows.win_shell"]

        self.assertIn("LocalContentCachePath", script)
        self.assertIn("ContentDir", script)
        self.assertIn("IIS:\\Sites\\WSUS Administration\\Content", script)
        move_lines = [line.strip() for line in script.splitlines() if "& $wsusutil movecontent" in line]
        self.assertEqual(move_lines, ["$out = & $wsusutil movecontent $wantRoot $moveLog 2>&1"])
        self.assertNotIn("-skipcopy", move_lines[0])
        self.assertIn("API already names", script)
        self.assertIn("Refusing an unsupported direct registry repair", script)

    def test_reconcile_has_an_explicit_idempotent_nochange_path(self):
        task = named_task(CONTENT_RECONCILE_TASK)
        script = task["ansible.windows.win_shell"]

        self.assertIn("$changed = $false", script)
        self.assertIn("if (-not (Test-ContentPath $apiBefore $wantCache))", script)
        self.assertIn("if ($changed) { Write-Output 'changed' } else { Write-Output 'nochange' }", script)
        self.assertEqual(
            task["changed_when"],
            "__wsus_content_location__.stdout | trim == 'changed'",
        )

        # Content API calls must remain after the detached-SUSDB recovery boundary; otherwise a
        # killed relocation can no longer reach the code that reattaches its complete file pair.
        tasks = yaml.safe_load(TASK_FILE.read_text(encoding="utf-8"))
        ordered_names = [item.get("name") for item in walk_tasks(tasks)]
        self.assertLess(
            ordered_names.index(SUSDB_HEALTH_TASK),
            ordered_names.index(CONTENT_RECONCILE_TASK),
        )

    def test_service_acl_and_runtime_verifier_cover_the_exact_content_contract(self):
        users_acl = named_task(CONTENT_USERS_ACL_TASK)["ansible.windows.win_acl"]
        self.assertEqual(users_acl["path"], "{{ __content_dir__ }}")
        self.assertEqual(users_acl["user"], "BUILTIN\\Users")
        self.assertEqual(users_acl["rights"], "ReadAndExecute")
        self.assertEqual(users_acl["inherit"], "ContainerInherit, ObjectInherit")

        acl_task = named_task(CONTENT_ACL_TASK)["ansible.windows.win_acl"]
        self.assertEqual(acl_task["path"], "{{ __content_dir__ }}\\WsusContent")
        self.assertEqual(acl_task["user"], "NT AUTHORITY\\NETWORK SERVICE")
        self.assertEqual(acl_task["rights"], "FullControl")
        self.assertEqual(acl_task["inherit"], "ContainerInherit, ObjectInherit")

        verify_script = powershell_script(named_task(RUNTIME_VERIFY_TASK))
        for required in (
            "LocalContentCachePath",
            "ContentDir",
            "IIS:\\Sites\\WSUS Administration\\Content",
            "S-1-5-32-545",
            "S-1-5-20",
            "Test-RequiredAllowAce",
        ):
            self.assertIn(required, verify_script)


class BootstrapInvocationContractTest(unittest.TestCase):
    def test_stale_marker_stops_old_work_and_starts_one_owned_category_sync(self):
        task = named_task(BOOTSTRAP_TASK)
        script = task["ansible.windows.win_shell"]

        stop_index = script.index("$s.StopSynchronization()")
        snapshot_index = script.index("$preHistoryIds = @{}")
        start_index = script.index("$s.StartSynchronizationForCategoryOnly()")
        self.assertLess(stop_index, snapshot_index)
        self.assertLess(snapshot_index, start_index)
        self.assertIn("$preHistoryIds[[string]$entry.Id] = $true", script)
        self.assertIn("-not $preHistoryIds.ContainsKey([string]$_.Id)", script)
        self.assertIn("[bool]$_.StartedManually", script)
        self.assertIn("$_.StartTime.ToUniversalTime() -ge $requestFloorUtc", script)
        self.assertIn("$invocationHistory.Count -ne 1", script)
        self.assertIn("[string]$completed.Result -ne 'Succeeded'", script)
        self.assertIn("category_bootstrap_history_id", script)
        self.assertIn("-Value ([string]$completed.Id)", script)
        history_marker_index = script.index("-Name 'category_bootstrap_history_id'")
        fingerprint_marker_index = script.index("-Name 'category_bootstrap_fingerprint' -Value $fingerprint")
        self.assertLess(history_marker_index, fingerprint_marker_index)
        self.assertNotIn("$startedHere", script)
        self.assertNotIn("Write-Output 'completed'", script)
        self.assertEqual(
            task["changed_when"],
            "__wsus_bootstrap__.stdout | trim == 'changed'",
        )

    def test_runtime_verifier_recomputes_the_exact_bootstrap_fingerprint(self):
        bootstrap = named_task(BOOTSTRAP_TASK)
        task = named_task(RUNTIME_VERIFY_TASK)
        script = powershell_script(task)

        self.assertIn("$expectedFingerprint", script)
        self.assertIn("$marker.category_bootstrap_fingerprint -ne $expectedFingerprint", script)
        self.assertIn("$marker.category_bootstrap_history_id", script)
        self.assertIn("$markedHistory.Count -ne 1", script)
        self.assertIn("[string]($markedHistory[0].Result) -ne 'Succeeded'", script)
        self.assertIn("WSUS_LANGS", task["environment"])
        for key in ("UPSTREAM_SERVER", "UPSTREAM_PORT", "UPSTREAM_SSL", "REPLICA", "WSUS_LANGS"):
            with self.subTest(environment_key=key):
                self.assertEqual(task["environment"][key], bootstrap["environment"][key])
        self.assertNotIn(
            "[string]::IsNullOrWhiteSpace($marker.category_bootstrap_fingerprint)",
            script,
        )


class WsusApiConnectionContractTest(unittest.TestCase):
    def test_persisted_ssl_uses_a_process_scoped_pinned_loopback_session(self):
        helper = named_task(ROLE_BLOCK_TASK)["vars"]["__wsus_api_invoker__"]
        source = TASK_FILE.read_text(encoding="utf-8")

        self.assertIn("$usingSsl = [int]$setup.UsingSSL", helper)
        self.assertIn("if ($usingSsl -eq 0)", helper)
        self.assertIn("IIS:\\SslBindings\\0.0.0.0!", helper)
        self.assertIn("$boundThumbprint -notmatch '^[0-9A-F]{40}$'", helper)
        self.assertIn("$certificate.GetCertHashString().Replace(' ', '')", helper)
        self.assertIn("}.GetNewClosure()", helper)
        self.assertIn("[System.Net.Security.RemoteCertificateValidationCallback]$pinnedCallback", helper)
        self.assertIn(
            "Get-WsusServer -Name '127.0.0.1' -PortNumber $port -UseSsl -ErrorAction Stop",
            helper,
        )
        self.assertIn("} finally {", helper)
        self.assertIn(
            "[System.Net.ServicePointManager]::ServerCertificateValidationCallback = $previousCallback",
            helper,
        )
        self.assertNotIn("win_hosts", source)
        self.assertNotIn("LocalMachine\\Root", source)
        self.assertNotIn("X509Store('Root', 'LocalMachine')", source)

    def test_every_wsus_api_actor_uses_the_shared_session_and_no_direct_cmdlet(self):
        expected_tasks = {
            SUSDB_HEALTH_TASK,
            CONTENT_RECONCILE_TASK,
            LANGUAGE_TASK,
            UPSTREAM_TASK,
            BOOTSTRAP_TASK,
            RUNTIME_VERIFY_TASK,
        }
        tasks = yaml.safe_load(TASK_FILE.read_text(encoding="utf-8"))
        actual_tasks = set()
        for task in walk_tasks(tasks):
            if not any(
                module in task
                for module in (
                    "ansible.windows.win_shell",
                    "ansible.windows.win_powershell",
                )
            ):
                continue
            script = powershell_script(task)
            self.assertNotIn("Get-WsusServer", script, task.get("name", "<unnamed>"))
            if "Invoke-LocalWsusApi" in script:
                actual_tasks.add(task["name"])
                self.assertIn("{{ __wsus_api_invoker__ }}", script)

        self.assertEqual(actual_tasks, expected_tasks)


class WsusPoolContractTest(unittest.TestCase):
    def test_runtime_verifier_rechecks_every_declared_pool_tuning_value(self):
        actor = named_task(WSUSPOOL_TASK)["community.windows.win_iis_webapppool"]
        self.assertEqual(
            set(actor["attributes"]),
            {
                "queueLength",
                "recycling.periodicRestart.privateMemory",
                "recycling.periodicRestart.memory",
                "recycling.periodicRestart.time",
                "processModel.idleTimeout",
                "processModel.pingingEnabled",
            },
        )

        verifier = named_task(RUNTIME_VERIFY_TASK)
        script = powershell_script(verifier)
        for property_path in actor["attributes"]:
            with self.subTest(property_path=property_path):
                self.assertIn(f"$pool.{property_path}", script)

        self.assertIn("WsusPool tuning differs from the desired", script)
        actual_environment = {
            key: verifier["environment"][key]
            for key in verifier["environment"]
            if key.startswith("WSUSPOOL_")
        }
        self.assertEqual(
            actual_environment,
            {
                "WSUSPOOL_QUEUE_LENGTH": "{{ config.wsuspool.queue_length | int }}",
                "WSUSPOOL_PRIVATE_MEMORY_KB": "{{ config.wsuspool.private_memory_kb | int }}",
                "WSUSPOOL_VIRTUAL_MEMORY_KB": "{{ config.wsuspool.virtual_memory_kb | int }}",
                "WSUSPOOL_PERIODIC_RESTART": "{{ config.wsuspool.periodic_restart }}",
                "WSUSPOOL_IDLE_TIMEOUT": "{{ config.wsuspool.idle_timeout }}",
                "WSUSPOOL_PINGING_ENABLED": "{{ config.wsuspool.pinging_enabled | bool | lower }}",
            },
        )


class HttpsListenerContractTest(unittest.TestCase):
    def test_every_certificate_gate_requires_explicit_server_authentication_eku(self):
        expected_calls = {
            TLS_STORE_PROBE_TASK: "Test-ServerAuthenticationEku $cert",
            TLS_PFX_VALIDATE_TASK: "Test-ServerAuthenticationEku $cert",
            RUNTIME_VERIFY_TASK: "Test-ServerAuthenticationEku $certificate",
        }
        for task_name, expected_call in expected_calls.items():
            with self.subTest(task=task_name):
                script = powershell_script(named_task(task_name))
                self.assertIn("Test-ServerAuthenticationEku", script)
                self.assertIn("$extension.Oid.Value -ne '2.5.29.37'", script)
                self.assertIn("$usage.Value -eq '1.3.6.1.5.5.7.3.1'", script)
                self.assertIn(expected_call, script)
                self.assertIn("return $false", script)
                self.assertNotIn("2.5.29.37.0", script)

        pfx_script = named_task(TLS_PFX_VALIDATE_TASK)["ansible.windows.win_shell"]
        self.assertIn("an absent EKU extension is not accepted", pfx_script)

    def test_binding_converges_and_verifies_exact_wildcard_empty_host_listener(self):
        task = named_task(TLS_BINDING_TASK)
        module = task["ansible.windows.win_powershell"]
        script = module["script"]

        self.assertEqual(module["error_action"], "stop")
        self.assertNotIn("ansible.windows.win_shell", task)
        self.assertNotIn("changed_when", task)
        self.assertIn("$Ansible.Changed = $false", script)
        self.assertIn("$Ansible.Changed = $changed", script)
        self.assertLess(
            script.index("$Ansible.Changed = $false"),
            script.index("$changed = $false"),
        )
        self.assertLess(
            script.index("$Ansible.Changed = $changed"),
            script.index("if ($changed) { Write-Output 'changed'"),
        )
        self.assertIn("$desiredBinding = '*:' + $port + ':'", script)
        self.assertIn("Get-WebBinding -Name $configuredSite.Name -ErrorAction Stop", script)
        self.assertNotIn(
            "Get-WebBinding -Name $configuredSite.Name -Protocol", script
        )
        self.assertIn("'^(?<address>.*):(?<port>[0-9]{1,5}):(?<host>.*)$'", script)
        self.assertIn("'^(?<port>[0-9]{1,5})(?::|$)'", script)
        self.assertIn("Site = [string]$configuredSite.Name", script)
        self.assertIn("Protocol = [string]$configuredBinding.protocol", script)
        foreign_guard = script.index("if ($foreignBindings.Count -gt 0)")
        mutation_guard = script.index(
            "if ($bindingDrift -or $certificateDriftBefore)"
        )
        self.assertLess(foreign_guard, mutation_guard)
        self.assertIn("refusing mutation", script[foreign_guard:mutation_guard])
        self.assertIn("function Get-WsusHttpsBindingRecords", script)
        self.assertIn("$ownedHttpsBindings.Count -ne 1", script)
        self.assertIn("$desiredBindings.Count -ne 1", script)
        self.assertIn("$nonDesiredTargetPortBindings.Count -gt 0", script)
        self.assertIn("[int]($desiredBindings[0].SslFlags) -ne 0", script)
        self.assertIn("$boundBefore = Get-Item $sslPath", script)
        self.assertIn("$certificateDriftBefore = -not $boundBefore", script)

        stop = script.index(
            "Stop-Website -Name $siteName -ErrorAction Stop | Out-Null"
        )
        remove_binding = script.index("Remove-WebBinding -Name $siteName")
        create_binding = script.index(
            "New-WebBinding -Name $siteName -Protocol https"
        )
        replace_certificate = script.index("Remove-Item $sslPath -ErrorAction Stop")
        post_binding_probe = script.index(
            "$bound = Get-Item $sslPath -ErrorAction SilentlyContinue",
            create_binding,
        )
        post_binding_drift = script.index("$certificateDrift = -not $bound", post_binding_probe)
        self.assertLess(mutation_guard, stop)
        self.assertLess(stop, remove_binding)
        self.assertLess(stop, create_binding)
        self.assertLess(create_binding, post_binding_probe)
        self.assertLess(post_binding_probe, post_binding_drift)
        self.assertLess(post_binding_drift, replace_certificate)
        self.assertIn("for ($attempt = 0; $attempt -lt 20; $attempt++)", script)
        self.assertIn("did not stop within 10 seconds", script)
        self.assertIn("-Confirm:$false | Out-Null", script)
        self.assertIn(
            "foreach ($candidate in @($ownedHttpsBindings) + @($ownedTargetPortBindings))",
            script,
        )
        self.assertIn("$seenBindings.ContainsKey($key)", script)
        self.assertIn("WSUS HTTP payload binding on 8530", script)
        self.assertIn("-IPAddress '*' -SslFlags 0", script)
        self.assertIn("$verifyOwnedBindings.Count -ne 1", script)
        self.assertIn("$verifyOwnedHttpsBindings.Count -ne 1", script)
        self.assertIn("exactly one HTTPS binding total", script)
        self.assertIn("[int]($verifyOwnedBindings[0].SslFlags) -ne 0", script)
        self.assertNotIn("Restart-Service", script)
        self.assertNotIn("Stop-Service", script)
        self.assertNotIn("Start-Website", script)
        self.assertEqual(script.count("Write-Output 'changed'"), 1)
        self.assertEqual(script.count("Write-Output 'nochange'"), 1)
        self.assertEqual(task["register"], "__tls_binding__")

        verify_script = powershell_script(named_task(RUNTIME_VERIFY_TASK))
        self.assertIn("$desiredBinding = '*:' + [int]$env:TLS_PORT + ':'", verify_script)
        self.assertIn("$siteBindings = @(Get-WebBinding", verify_script)
        self.assertIn("$desiredSiteBindings = @($siteBindings", verify_script)
        self.assertIn("$siteBindings.Count -ne 1", verify_script)
        self.assertIn("$desiredSiteBindings.Count -ne 1", verify_script)
        self.assertIn("[int]($desiredSiteBindings[0].sslFlags) -ne 0", verify_script)
        self.assertIn("exactly one HTTPS binding total", verify_script)

    def test_live_probe_sends_http_request_with_intended_sni_and_host(self):
        task = named_task(TLS_LIVE_TASK)
        script = task["ansible.windows.win_shell"]

        self.assertIn("$ssl.AuthenticateAsClient($env:TLS_DNS_NAME)", script)
        self.assertIn("GET /ClientWebService/client.asmx HTTP/1.1", script)
        self.assertIn("Host: $($env:TLS_DNS_NAME):$($env:TLS_PORT)", script)
        self.assertIn("did not return HTTP 200", script)
        self.assertEqual(task["changed_when"], False)

    def test_listener_activation_is_bounded_idempotent_and_site_scoped(self):
        helper = named_task(ROLE_BLOCK_TASK)["vars"][
            "__wsus_https_listener_reconciler__"
        ]

        ssl_value_guard = helper.index("$usingSslText -notmatch '^[01]$'")
        port_read = helper.index("$portText = [string]$setup.PortNumber")
        pre_ssl_recovery = helper.index("if ($usingSsl -eq 0)")
        absent_guard = helper.index("if (-not (Test-Path -LiteralPath $sitePath))")
        auto_start_mutation = helper.index(
            "Set-ItemProperty -LiteralPath $sitePath -Name serverAutoStart -Value $true | Out-Null"
        )
        self.assertLess(ssl_value_guard, port_read)
        self.assertLess(port_read, pre_ssl_recovery)
        self.assertLess(absent_guard, auto_start_mutation)
        self.assertIn("$port -lt 1 -or $port -gt 65535", helper)
        self.assertNotIn("$env:TLS_PORT", helper)
        self.assertIn("Get-WebItemState -PSPath $sitePath -ErrorAction Stop", helper)
        self.assertIn("function Start-WsusWebsiteBounded", helper)
        self.assertEqual(
            helper.count(
                "Start-Website -Name $siteName -ErrorAction Stop | Out-Null"
            ),
            1,
        )
        self.assertIn("$siteState -eq 'Started'", helper)
        self.assertIn("for ($attempt = 0; $attempt -lt 10; $attempt++)", helper)
        self.assertIn("if (Test-LoopbackListener $port)", helper)
        self.assertIn("if (-not $listenerReady)", helper)
        self.assertNotIn("$tlsChanged", helper)
        self.assertIn(
            "Stop-Website -Name $siteName -ErrorAction Stop | Out-Null", helper
        )
        self.assertNotIn("Restart-Service", helper)
        self.assertNotIn("Stop-Service", helper)
        self.assertIn("$connect.Wait(1000)", helper)
        self.assertIn("for ($attempt = 0; $attempt -lt 30; $attempt++)", helper)
        self.assertIn("$siteState -eq 'Started' -and $listenerReady", helper)
        self.assertIn("serverAutoStart=true", helper)
        auto_start_settle = helper.index(
            "# reconciliation a bounded chance to start the site before issuing an explicit start."
        )
        explicit_start = helper.rindex("Start-WsusWebsiteBounded $port")
        self.assertLess(auto_start_mutation, auto_start_settle)
        self.assertLess(auto_start_settle, explicit_start)

        retry_helper = helper[
            helper.index("function Start-WsusWebsiteBounded") : helper.index(
                "function Test-LoopbackListener"
            )
        ]
        self.assertIn("for ($attempt = 0; $attempt -lt 20; $attempt++)", retry_helper)
        self.assertIn("[int64]$current.HResult -eq -2147024713", helper)
        self.assertIn("$current = $current.InnerException", helper)
        self.assertIn("if (-not (Test-AlreadyExistsHResult $_.Exception))", retry_helper)
        self.assertIn(
            "Start-Website failed with a non-retryable exception", retry_helper
        )
        self.assertIn("Format-ExceptionChain $_.Exception", retry_helper)
        self.assertIn("Get-WsusListenerFailureDetailsSafe $listenerPort", retry_helper)
        self.assertIn("Assert-WsusPortExclusive $listenerPort", retry_helper)
        self.assertIn("view=requestq", retry_helper)
        self.assertIn("Test-HttpSysPortRegistration", retry_helper)
        self.assertIn("if ($currentState -eq 'Started')", retry_helper)
        self.assertIn("lastAlreadyExists=[", retry_helper)
        self.assertIn("function Repair-WsusOwnedPortBindings", helper)
        self.assertIn("if (Repair-WsusOwnedPortBindings $port)", helper)
        self.assertIn("Remove-WebBinding -Name $siteName", helper)
        self.assertIn(
            "New-WebBinding -Name $siteName -Protocol https -Port $listenerPort",
            helper,
        )
        self.assertIn("WSUS site target-port bindings became unnormalized", helper)
        self.assertIn("$owned.Count -eq 1 -and $desired.Count -eq 1", helper)
        self.assertIn("function Get-OrRepairCurrentSslMapping", helper)
        self.assertIn("Preserve the currently serving certificate here", helper)
        self.assertIn("$recoveryThumbprint = '{{ config.tls.thumbprint | trim | upper }}'", helper)
        self.assertIn("configured TLS recovery thumbprint is invalid", helper)
        self.assertIn("the exact pinned recovery leaf with", helper)
        self.assertIn("Stop-WsusWebsiteBounded 'pre-API SSL mapping recovery'", helper)
        self.assertIn("New-Item $sslPath -Value $recoveryCertificate | Out-Null", helper)
        self.assertIn("pre-API SSL mapping recovery did not persist thumbprint", helper)
        self.assertIn("$mapping = Get-OrRepairCurrentSslMapping $listenerPort", helper)
        self.assertIn("New-Item $mapping.Path -Value $mapping.Certificate | Out-Null", helper)
        self.assertIn("$verifyMapping = Get-Item $mapping.Path -ErrorAction Stop", helper)
        repair_call = helper.index("if (Repair-WsusOwnedPortBindings $port)")
        mapping_preflight = helper.index(
            "$currentSslMapping = Get-OrRepairCurrentSslMapping $port"
        )
        self.assertIn("$currentSslMapping.Changed", helper)
        normalized_guard = retry_helper.index(
            "WSUS site target-port bindings became unnormalized"
        )
        start_command = retry_helper.index(
            "Start-Website -Name $siteName -ErrorAction Stop | Out-Null"
        )
        self.assertLess(mapping_preflight, repair_call)
        self.assertLess(repair_call, helper.rindex("Start-WsusWebsiteBounded $port"))
        self.assertLess(mapping_preflight, helper.rindex("Start-WsusWebsiteBounded $port"))
        self.assertLess(normalized_guard, start_command)
        self.assertIn("function Repair-PreSslWsusApiAccess", helper)
        self.assertIn("if (Repair-PreSslWsusApiAccess)", helper)
        self.assertIn("-Name 'sslFlags' -Value 0 -ErrorAction Stop | Out-Null", helper)
        self.assertNotIn("-Value 'None'", helper)
        self.assertIn("pre-SSL WSUS API access rollback did not persist", helper)
        self.assertIn("type=[' + $valueType +", helper)
        self.assertIn("expected=[None|0]", helper)
        zero_write = helper.index("-Name 'sslFlags' -Value 0")
        rollback_verify = helper.index(
            "pre-SSL WSUS API access rollback did not persist"
        )
        self.assertLess(zero_write, rollback_verify)
        pre_ssl_repair_call = helper.index("if (Repair-PreSslWsusApiAccess)")
        pre_ssl_start_call = helper.index("Start-WsusWebsiteBounded $port $false")
        self.assertLess(pre_ssl_repair_call, pre_ssl_start_call)
        self.assertIn("function Limit-DiagnosticText", helper)
        self.assertIn("$text.Substring(0, $maxLength)", helper)
        self.assertNotIn("Write-Output", retry_helper)
        for limit in ("2048", "4096", "512"):
            with self.subTest(diagnostic_limit=limit):
                self.assertIn(limit, helper)
        for diagnostic in (
            "W3SVC=",
            "allBindings=[",
            "httpSysSsl=[",
            "httpSysIpListen=[",
            "httpSysServiceState=[",
            "recentWasW3svcHttpEvents=[",
        ):
            with self.subTest(diagnostic=diagnostic):
                self.assertIn(diagnostic, helper)

        expected_invocations = {
            TLS_PRE_API_LISTENER_TASK,
            TLS_LISTENER_TASK,
        }
        for task_name in expected_invocations:
            with self.subTest(task=task_name):
                task = named_task(task_name)
                module = task["ansible.windows.win_powershell"]
                script = module["script"]
                self.assertIn("{{ __wsus_https_listener_reconciler__ }}", script)
                self.assertIn("Invoke-LocalWsusHttpsListenerReconcile", script)
                self.assertNotIn("environment", task)
                self.assertEqual(module["error_action"], "stop")
                self.assertNotIn("ansible.windows.win_shell", task)
                self.assertNotIn("changed_when", task)
                self.assertIn("$listenerResult = @(", script)
                self.assertIn("$listenerResult.Count -ne 1", script)
                self.assertIn("-notin @('changed', 'nochange')", script)
                self.assertIn("$Ansible.Changed = $false", script)
                self.assertIn(
                    "$Ansible.Changed = [string]$listenerResult[0] -eq 'changed'",
                    script,
                )
                self.assertLess(
                    script.index("$Ansible.Changed = $false"),
                    script.index("$listenerResult = @("),
                )
                self.assertIn("Write-Output ([string]$listenerResult[0])", script)

        tasks = list(walk_tasks(yaml.safe_load(TASK_FILE.read_text(encoding="utf-8"))))
        names = [item.get("name") for item in tasks]
        listener_invocations = {
            item["name"]
            for item in tasks
            if (
                "Invoke-LocalWsusHttpsListenerReconcile"
                in item.get("ansible.windows.win_powershell", {}).get("script", "")
                or "Invoke-LocalWsusHttpsListenerReconcile"
                in item.get("ansible.windows.win_shell", "")
            )
        }
        self.assertEqual(listener_invocations, expected_invocations)
        self.assertLess(names.index(WSUS_SERVICES_TASK), names.index(TLS_PRE_API_LISTENER_TASK))
        for api_task in (
            SUSDB_HEALTH_TASK,
            CONTENT_RECONCILE_TASK,
            LANGUAGE_TASK,
            UPSTREAM_TASK,
            BOOTSTRAP_TASK,
            RUNTIME_VERIFY_TASK,
        ):
            with self.subTest(precedes_api_task=api_task):
                self.assertLess(names.index(TLS_PRE_API_LISTENER_TASK), names.index(api_task))
        self.assertLess(names.index(TLS_BINDING_TASK), names.index(TLS_LISTENER_TASK))
        self.assertLess(names.index(TLS_CONFIGURESSL_TASK), names.index(TLS_LISTENER_TASK))
        self.assertLess(names.index(TLS_LISTENER_TASK), names.index(TLS_LIVE_TASK))
        self.assertLess(names.index(TLS_LIVE_TASK), names.index(RUNTIME_VERIFY_TASK))

    def test_ssl_vdir_convergence_uses_numeric_flags_and_two_phase_proof(self):
        task = named_task(TLS_CONFIGURESSL_TASK)
        script = task["ansible.windows.win_shell"]
        exact_vdirs = [
            "ApiRemoting30",
            "ClientWebService",
            "DSSAuthWebService",
            "ServerSyncWebService",
            "SimpleAuthWebService",
        ]

        vdirs_block = script[
            script.index("$vdirs = @(") : script.index("$changed = $false")
        ]
        actual_vdirs = [
            line.strip().rstrip(",").strip("'")
            for line in vdirs_block.splitlines()
            if line.strip().startswith("'")
        ]
        self.assertEqual(actual_vdirs, exact_vdirs)
        for excluded_vdir in (
            "Content",
            "Inventory",
            "ReportingWebService",
            "SelfUpdate",
        ):
            self.assertNotIn(excluded_vdir, vdirs_block)

        self.assertIn("function Get-WsusAccessSslState", script)
        self.assertIn("function Test-ExactRequiredSsl", script)
        self.assertIn("function Assert-WsusVdirsRequireSsl", script)
        self.assertIn("function Repair-WsusVdirsRequireSsl", script)
        self.assertIn("-PSPath 'MACHINE/WEBROOT/APPHOST'", script)
        self.assertIn("-Location $location", script)
        self.assertIn("-Filter 'system.webServer/security/access'", script)
        self.assertIn("-Name 'sslFlags' `\n            -Value 8 `", script)
        self.assertIn("-ErrorAction Stop | Out-Null", script)
        self.assertNotIn("-Value 'Ssl'", script)
        self.assertIn("$state.Text -eq 'Ssl' -or $state.Text -eq '8'", script)

        numeric_write = script.index("-Value 8")
        immediate_read = script.index(
            "$afterWrite = Get-WsusAccessSslState $location", numeric_write
        )
        immediate_assert = script.index(
            "IIS access.sslFlags write did not persist", immediate_read
        )
        full_assert = script.index("Assert-WsusVdirsRequireSsl", immediate_assert)
        self.assertLess(numeric_write, immediate_read)
        self.assertLess(immediate_read, immediate_assert)
        self.assertLess(immediate_assert, full_assert)

        repair_calls = [
            index
            for index in range(len(script))
            if script.startswith("if (Repair-WsusVdirsRequireSsl)", index)
        ]
        self.assertEqual(len(repair_calls), 2)
        configuressl = script.index("$out = & $wsusutil configuressl $dns")
        registry_re_read = script.index(
            "$after = Get-ItemProperty -Path $setupPath -ErrorAction Stop"
        )
        self.assertLess(repair_calls[0], configuressl)
        self.assertLess(configuressl, repair_calls[1])
        self.assertLess(repair_calls[1], registry_re_read)

        self.assertIn("does not require exact SSL", script)
        self.assertIn("location=' + $state.Location", script)
        self.assertIn("type=[' + $state.Type", script)
        self.assertIn("expected=[Ssl|8]", script)
        self.assertEqual(script.count("Write-Output 'changed'"), 1)
        self.assertEqual(script.count("Write-Output 'nochange'"), 1)
        self.assertEqual(
            task["changed_when"],
            "__tls_configuressl__.stdout | trim == 'changed'",
        )

        verifier_task = named_task(RUNTIME_VERIFY_TASK)
        verifier = powershell_script(verifier_task)
        verifier_vdir_loop = (
            "foreach ($name in @('ApiRemoting30', 'ClientWebService', "
            "'DSSAuthWebService', 'ServerSyncWebService', "
            "'SimpleAuthWebService')) {"
        )
        self.assertIn(verifier_vdir_loop, verifier)
        self.assertIn("-Name 'sslFlags' `\n            -ErrorAction Stop", verifier)
        self.assertIn("IIS returned no access.sslFlags value for", verifier)
        self.assertIn("does not require exact SSL: sslFlags=[", verifier)
        self.assertIn("] type=[", verifier)
        self.assertIn("expected=[Ssl|8]", verifier)
        self.assertNotIn("Set-WebConfigurationProperty", verifier)
        self.assertFalse(verifier_task.get("changed_when", False))

    def test_runtime_verifier_rechecks_site_start_and_auto_start_before_the_api(self):
        task = named_task(RUNTIME_VERIFY_TASK)
        module = task["ansible.windows.win_powershell"]
        script = module["script"]

        self.assertEqual(module["error_action"], "stop")
        self.assertNotIn("ansible.windows.win_shell", task)
        self.assertNotIn("changed_when", task)
        self.assertEqual(script.splitlines()[0], "$ErrorActionPreference = 'Stop'")
        self.assertEqual(script.splitlines()[1], "$Ansible.Changed = $false")
        self.assertEqual(script.count("Write-Output 'healthy'"), 1)
        state_check = script.index("$wsusSiteState -ne 'Started'")
        api_helper = script.index("{{ __wsus_api_invoker__ }}")
        self.assertLess(state_check, api_helper)
        self.assertIn("IIS:\\Sites\\WSUS Administration", script)
        self.assertIn("Get-WebItemState -PSPath $wsusSitePath -ErrorAction Stop", script)
        self.assertIn("$wsusSite.serverAutoStart", script)


if __name__ == "__main__":
    unittest.main()

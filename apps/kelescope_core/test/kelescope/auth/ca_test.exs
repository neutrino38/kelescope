defmodule Kelescope.Auth.CATest do
  use ExUnit.Case, async: true

  alias Kelescope.Auth.CA

  setup do
    dir = Path.join(System.tmp_dir!(), "kelescope-ca-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "creates the authority on first use", %{dir: dir} do
    assert {:ok, {certificate, _key}} = CA.load_or_create(dir, "kelescope.example.com")

    assert File.exists?(CA.key_path(dir))
    assert File.exists?(CA.certificate_path(dir))
    assert mode(CA.key_path(dir)) == 0o600
    assert mode(CA.certificate_path(dir)) == 0o644

    assert X509.Certificate.subject(certificate, "CN") == ["kelescope CA kelescope.example.com"]
  end

  test "reuses the authority already on disk", %{dir: dir} do
    {:ok, {certificate, _}} = CA.load_or_create(dir, "kelescope.example.com")
    {:ok, {again, _}} = CA.load_or_create(dir, "other.example.com")

    assert X509.Certificate.serial(certificate) == X509.Certificate.serial(again)
  end

  test "issues a client certificate signed by the authority", %{dir: dir} do
    {:ok, issued} = CA.issue(dir, "kelescope.example.com", "prenom.nom", "poste bureau", 365)

    assert issued.label == "poste bureau"
    assert DateTime.diff(issued.expires_at, issued.issued_at, :day) == 365
    assert String.match?(issued.fingerprint, ~r/^[0-9a-f]{64}$/)
    assert byte_size(issued.password) == 16
  end

  test "the fingerprint survives a DER round trip", %{dir: dir} do
    {:ok, issued} = CA.issue(dir, "kelescope.example.com", "prenom.nom", "poste", 365)

    der = extract_der(issued)

    assert CA.fingerprint(der) == issued.fingerprint

    assert der |> X509.Certificate.from_der!() |> X509.Certificate.to_der() |> CA.fingerprint() ==
             issued.fingerprint
  end

  test "openssl reads the bundle back with the password", %{dir: dir} do
    {:ok, issued} = CA.issue(dir, "kelescope.example.com", "prenom.nom", "poste", 365)

    path = Path.join(dir, "bundle.p12")
    File.write!(path, issued.pkcs12)

    {output, 0} =
      System.cmd("openssl", ["pkcs12", "-info", "-in", path, "-nodes", "-passin", "env:PW"],
        env: [{"PW", issued.password}],
        stderr_to_stdout: true
      )

    assert output =~ "CN=prenom.nom"
    assert output =~ "PRIVATE KEY"
    assert output =~ "CN=kelescope CA kelescope.example.com"

    assert {_, 1} =
             System.cmd(
               "openssl",
               ["pkcs12", "-info", "-in", path, "-nodes", "-passin", "pass:x"],
               stderr_to_stdout: true
             )
  end

  defp extract_der(issued) do
    dir = Path.join(System.tmp_dir!(), "kelescope-der-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "bundle.p12")
    File.write!(path, issued.pkcs12)

    {pem, 0} =
      System.cmd(
        "openssl",
        ["pkcs12", "-in", path, "-clcerts", "-nokeys", "-passin", "env:PW"],
        env: [{"PW", issued.password}]
      )

    File.rm_rf!(dir)

    pem |> X509.Certificate.from_pem!() |> X509.Certificate.to_der()
  end

  defp mode(path) do
    %File.Stat{mode: mode} = File.stat!(path)
    Bitwise.band(mode, 0o777)
  end
end

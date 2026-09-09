defmodule Kelescope.Auth.CA do
  @moduledoc """
  Certificate authority of the instance. It issues the client certificates and
  builds the PKCS#12 bundles handed to administrators.

  kelescope does not trust this authority to identify anyone: a certificate is
  accepted on its registered fingerprint alone (ADR-004).
  """

  @ca_validity_days 3650
  @password_length 16

  def key_path(dir), do: Path.join(dir, "ca.key")
  def certificate_path(dir), do: Path.join(dir, "ca.crt")

  @doc """
  Loads the authority, creating it on first use.
  """
  @spec load_or_create(String.t(), String.t()) :: {:ok, {tuple(), tuple()}} | {:error, term()}
  def load_or_create(dir, host) do
    case File.read(key_path(dir)) do
      {:ok, key_pem} ->
        with {:ok, certificate_pem} <- File.read(certificate_path(dir)) do
          {:ok, {X509.Certificate.from_pem!(certificate_pem), X509.PrivateKey.from_pem!(key_pem)}}
        end

      {:error, :enoent} ->
        create(dir, host)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create(dir, host) do
    key = X509.PrivateKey.new_ec(:secp256r1)

    certificate =
      X509.Certificate.self_signed(key, "/CN=kelescope CA #{host}",
        template: :root_ca,
        validity: @ca_validity_days
      )

    with :ok <- File.write(key_path(dir), X509.PrivateKey.to_pem(key)),
         :ok <- File.chmod(key_path(dir), 0o600),
         :ok <- File.write(certificate_path(dir), X509.Certificate.to_pem(certificate)),
         :ok <- File.chmod(certificate_path(dir), 0o644) do
      {:ok, {certificate, key}}
    end
  end

  @doc """
  Issues a client certificate for `id` and wraps it in a password-protected
  PKCS#12 bundle. The private key is never written to disk on this side.
  """
  @spec issue(String.t(), String.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def issue(dir, host, id, label, days) do
    with {:ok, {ca_certificate, ca_key}} <- load_or_create(dir, host) do
      key = X509.PrivateKey.new_ec(:secp256r1)
      issued_at = DateTime.utc_now() |> DateTime.truncate(:second)
      expires_at = DateTime.add(issued_at, days, :day)

      certificate =
        X509.Certificate.new(
          X509.PublicKey.derive(key),
          "/CN=#{id}",
          ca_certificate,
          ca_key,
          validity: X509.Certificate.Validity.new(DateTime.add(issued_at, -60), expires_at),
          extensions: [
            ext_key_usage: X509.Certificate.Extension.ext_key_usage([:clientAuth])
          ]
        )

      password = generate_password()

      with {:ok, pkcs12} <-
             to_pkcs12(
               X509.Certificate.to_pem(certificate),
               X509.PrivateKey.to_pem(key),
               X509.Certificate.to_pem(ca_certificate),
               password,
               "#{id} - #{label}"
             ) do
        der = X509.Certificate.to_der(certificate)

        {:ok,
         %{
           der: der,
           fingerprint: fingerprint(der),
           serial: X509.Certificate.serial(certificate),
           label: label,
           issued_at: issued_at,
           expires_at: expires_at,
           pkcs12: pkcs12,
           password: password
         }}
      end
    end
  end

  @doc """
  SHA-256 of the DER-encoded certificate, lowercase hex. This is what
  identifies a workstation.
  """
  @spec fingerprint(binary()) :: String.t()
  def fingerprint(der) when is_binary(der) do
    :sha256 |> :crypto.hash(der) |> Base.encode16(case: :lower)
  end

  # openssl reads each PEM once from a stream it cannot rewind, so the
  # certificate, the key and the authority each need their own descriptor.
  # Nothing is written to disk: the shell feeds all three from the environment.
  defp to_pkcs12(certificate_pem, key_pem, ca_pem, password, friendly_name) do
    command =
      ~s{printf '%s' "$KELESCOPE_PKCS12_CERT" | } <>
        ~s{openssl pkcs12 -export -in /dev/stdin } <>
        ~s{-inkey <(printf '%s' "$KELESCOPE_PKCS12_KEY") } <>
        ~s{-certfile <(printf '%s' "$KELESCOPE_PKCS12_CA") } <>
        ~s{-name "$KELESCOPE_PKCS12_NAME" -passout env:KELESCOPE_PKCS12_PASSWORD}

    case System.cmd("bash", ["-c", command],
           env: [
             {"KELESCOPE_PKCS12_CERT", certificate_pem},
             {"KELESCOPE_PKCS12_KEY", key_pem},
             {"KELESCOPE_PKCS12_CA", ca_pem},
             {"KELESCOPE_PKCS12_PASSWORD", password},
             {"KELESCOPE_PKCS12_NAME", friendly_name}
           ],
           stderr_to_stdout: false
         ) do
      {pkcs12, 0} -> {:ok, pkcs12}
      {_, status} -> {:error, {:pkcs12_failed, status}}
    end
  end

  defp generate_password do
    @password_length
    |> :crypto.strong_rand_bytes()
    |> Base.encode32(padding: false)
    |> binary_part(0, @password_length)
  end
end

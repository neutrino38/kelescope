// WebAuthn ceremonies and the two side effects a LiveView cannot perform on
// its own: submitting a form to a controller, and saving a file.

const bytes = (value) => Uint8Array.from(atob(value), (c) => c.charCodeAt(0))

const decode = (value) => bytes(value.replace(/-/g, "+").replace(/_/g, "/"))

const encode = (buffer) =>
  btoa(String.fromCharCode(...new Uint8Array(buffer)))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=/g, "")

const credentialDescriptors = (list) =>
  (list || []).map((descriptor) => ({...descriptor, id: decode(descriptor.id)}))

export const Passkey = {
  mounted() {
    if (!window.PublicKeyCredential) {
      this.pushEvent("passkey:error", {
        message: "Ce navigateur ne gère pas les passkeys (WebAuthn).",
      })
      return
    }

    this.handleEvent("passkey:create", (options) => this.create(options))
    this.handleEvent("passkey:get", (options) => this.get(options))
    this.handleEvent("download", (payload) => this.download(payload))
  },

  async create(options) {
    try {
      const credential = await navigator.credentials.create({
        publicKey: {
          ...options,
          challenge: decode(options.challenge),
          user: {...options.user, id: decode(options.user.id)},
          excludeCredentials: credentialDescriptors(options.excludeCredentials),
        },
      })

      this.pushEvent("passkey:result", {
        id: credential.id,
        rawId: encode(credential.rawId),
        type: credential.type,
        response: {
          clientDataJSON: encode(credential.response.clientDataJSON),
          attestationObject: encode(credential.response.attestationObject),
        },
      })
    } catch (error) {
      this.fail(error)
    }
  },

  async get(options) {
    try {
      const assertion = await navigator.credentials.get({
        publicKey: {
          ...options,
          challenge: decode(options.challenge),
          allowCredentials: credentialDescriptors(options.allowCredentials),
        },
      })

      this.pushEvent("passkey:result", {
        id: assertion.id,
        rawId: encode(assertion.rawId),
        type: assertion.type,
        response: {
          clientDataJSON: encode(assertion.response.clientDataJSON),
          authenticatorData: encode(assertion.response.authenticatorData),
          signature: encode(assertion.response.signature),
          userHandle: assertion.response.userHandle && encode(assertion.response.userHandle),
        },
      })
    } catch (error) {
      this.fail(error)
    }
  },

  download({filename, content_type, data}) {
    const blob = new Blob([bytes(data)], {type: content_type})
    const url = URL.createObjectURL(blob)
    const link = document.createElement("a")
    link.href = url
    link.download = filename
    document.body.appendChild(link)
    link.click()
    document.body.removeChild(link)
    URL.revokeObjectURL(url)
  },

  fail(error) {
    this.pushEvent("passkey:error", {message: error.message || String(error)})
  },
}

export const AutoSubmit = {
  mounted() {
    this.el.submit()
  },
}

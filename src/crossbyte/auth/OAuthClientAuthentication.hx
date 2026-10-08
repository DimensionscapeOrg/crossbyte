package crossbyte.auth;

/**
 * How a confidential client proves itself to the token endpoint: where its
 * secret goes. Named as OpenID Connect's `token_endpoint_auth_method`, which a
 * provider's discovery document lists as `token_endpoint_auth_methods_supported`.
 *
 * A client with no secret (a public client using PKCE) sends none either
 * way.
 */
enum abstract OAuthClientAuthentication(String) to String {
	/**
	 * In the request body, beside the other parameters. What most providers
	 * take; RFC 6749 calls it NOT RECOMMENDED, and a provider configured for
	 * Basic alone refuses it as `invalid_client`.
	 */
	var SECRET_POST = "client_secret_post";

	/**
	 * In an HTTP Basic `Authorization` header: the client id and secret, each
	 * form-encoded, as RFC 6749 2.3.1 has it. Every provider must accept it.
	 */
	var SECRET_BASIC = "client_secret_basic";
}

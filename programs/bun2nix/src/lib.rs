//! Library for implementing parsing and conversion of [Bun](https://bun.sh/) lock files into a
//! [Nix](https://en.wikipedia.org/wiki/Nix_(package_manager)) expression.

#![warn(missing_docs)]

pub mod error;
pub mod lockfile;
pub mod nix_expression;
pub mod options;
pub mod package;

pub use error::{Error, Result};
pub use lockfile::Lockfile;
use nix_expression::NixExpression;
pub use options::Options;
pub use package::Package;

#[cfg(target_arch = "wasm32")]
use wasm_bindgen::prelude::*;

/// # Convert Bun Lockfile to a Nix expression
///
/// Takes a string input of the contents of a bun lockfile and converts it into a ready to use Nix expression which fetches the packages
#[cfg_attr(target_arch = "wasm32", wasm_bindgen)]
#[cfg_attr(target_arch = "wasm32", no_mangle)]
pub fn convert_lockfile_to_nix_expression(contents: String, options: Options) -> Result<String> {
    let lockfile = contents.parse::<Lockfile>()?;

    // Version 2 adds Bun parse-time validation without changing package tuples.
    if !matches!(lockfile.lockfile_version, 1 | 2) {
        return Err(Error::UnsupportedLockfileVersion(lockfile.lockfile_version));
    };

    let mut packages = lockfile.packages();
    packages.sort();
    packages.dedup_by(|a, b| a.name == b.name);

    NixExpression::new(packages)?.render_with_options(options)
}

#[cfg(test)]
mod tests {
    use super::{Error, Options, convert_lockfile_to_nix_expression};

    #[test]
    fn version_two_preserves_fetchers() {
        let lockfile = serde_json::json!({
            "lockfileVersion": 1,
            "packages": {
                "local": ["local@workspace:packages/local"],
                "example": [
                    "example@1.0.0",
                    "https://registry.example.org/example/-/example-1.0.0.tgz",
                    {},
                    "sha512-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="
                ]
            }
        });
        let options = Options {
            copy_prefix: "./".to_owned(),
        };
        let expected =
            convert_lockfile_to_nix_expression(lockfile.to_string(), options.clone()).unwrap();
        let mut version_two = lockfile;
        version_two["lockfileVersion"] = 2.into();
        let actual = convert_lockfile_to_nix_expression(version_two.to_string(), options).unwrap();
        assert_eq!(actual, expected);
        assert!(actual.contains("https://registry.example.org/example/-/example-1.0.0.tgz"));
        assert!(actual.contains("packages/local"));
    }

    #[test]
    fn unsupported_versions_are_rejected() {
        for version in [0, 3, 255] {
            let lockfile = serde_json::json!({ "lockfileVersion": version, "packages": {} });
            let result = convert_lockfile_to_nix_expression(
                lockfile.to_string(),
                Options {
                    copy_prefix: "./".to_owned(),
                },
            );
            assert!(
                matches!(result, Err(Error::UnsupportedLockfileVersion(value)) if value == version)
            );
        }
    }
}

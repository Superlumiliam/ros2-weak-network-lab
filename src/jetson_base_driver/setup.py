from setuptools import setup

package_name = 'jetson_base_driver'

setup(
    name=package_name,
    version='0.1.0',
    packages=[package_name],
    data_files=[
        ('share/ament_index/resource_index/packages', ['resource/' + package_name]),
        ('share/' + package_name, ['package.xml', 'README.md', 'SOURCE.md']),
    ],
    install_requires=['setuptools'],
    zip_safe=True,
    maintainer='Project Maintainers',
    maintainer_email='maintainers@example.com',
    description='Jetson M1 base driver imported from the robot vendor workspace.',
    license='LicenseRef-Vendor-Unspecified',
    entry_points={
        'console_scripts': [
            'Mcnamu_driver_M1 = jetson_base_driver.Mcnamu_driver_M1:main',
        ],
    },
)

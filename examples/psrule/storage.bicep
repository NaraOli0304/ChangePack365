resource secureStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'cp365securefixture'
  location: 'eastus'
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    supportsHttpsTrafficOnly: true
  }
}

resource insecureStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'cp365insecurefixture'
  location: 'eastus'
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    supportsHttpsTrafficOnly: false
  }
}
